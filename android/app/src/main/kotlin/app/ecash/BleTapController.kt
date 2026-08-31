package org.fedimint.app.master

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.ArrayDeque
import java.util.UUID

/**
 * Native BLE transport for "tap to send" ecash.
 *
 * The rendezvous service UUID and the receiver's ephemeral public key are
 * exchanged over NFC (MainActivity's `ecashapp/nfc_tap` reader + the HCE publish
 * path). BLE then only carries the already-encrypted blob.
 *
 * ## Why the sender is the peripheral
 *
 * The obvious arrangement - receiver advertises, sender connects and writes - is
 * unusable on Android 17: the client's `writeCharacteristic`/`writeDescriptor`
 * both return SUCCESS and the completion callback never fires, so the transfer
 * stalls forever. The same code on Android 16 completes in ~100ms. Every other
 * GATT operation (connect, MTU exchange, discovery, notifications) works on 17.
 *
 * So the data travels the other way round, using only operations that work:
 *   - Sender advertises [serviceUuid], runs a GATT server, and **pushes** the
 *     blob to the connected central as a stream of notifications.
 *   - Receiver scans for that UUID, connects **without bonding**, and receives.
 *
 * The receiver never writes an attribute. In particular it never writes the CCCD
 * to subscribe: `setCharacteristicNotification` is a purely local registration,
 * and because both ends are this app the server simply notifies unconditionally
 * rather than waiting for a subscription it will never receive.
 *
 * Delivery is signalled by the receiver disconnecting once it has assembled the
 * whole payload - there is no acknowledgement channel back to the sender that
 * would not require a client write.
 *
 * All characteristics are unencrypted at the link layer (no pairing, by design);
 * the payload is already encrypted at the app layer (rust/ecashapp/src/tap_transfer.rs).
 *
 * Events emitted to Dart via [emit] (posted to the main thread):
 *   {event:"status", state:"advertising|scanning|connecting|connected|receiving|writing|sent|confirmed|stopped"}
 *   {event:"received", data:ByteArray}   // receiver assembled the full blob
 *   {event:"error",    message:String}
 */
@SuppressLint("MissingPermission")
class BleTapController(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    companion object {
        private const val TAG = "BleTap"

        /** Overall budget for one transfer, either role. */
        private const val TRANSFER_TIMEOUT_MS = 20_000L

        // Fixed characteristic UUIDs living inside the per-session rendezvous service.
        private val CHAR_PAYLOAD_UUID: UUID = UUID.fromString("e3c0f2a1-0b7d-4c6e-9a2f-1d5b0e7a0005")
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        private const val HEADER_VERSION: Byte = 1
        private const val DEFAULT_MTU = 23
        private const val ATT_NOTIFY_OVERHEAD = 3
        /**
         * Upper bound on one notification's value, just under the 514 bytes an
         * ATT_MTU of 517 allows.
         *
         * This was 180 when the payload travelled as characteristic *writes*: a
         * write of exactly (MTU - 3) could tip Android into a prepared "long
         * write", which the GATT server did not implement. Notifications have no
         * long-form equivalent - they are simply capped at MTU - 3 - so that
         * constraint does not apply and the old cap only cost frames.
         */
        private const val MAX_SAFE_CHUNK = 512

        /** Sanity bound on the advertised payload length in the header. */
        private const val MAX_PAYLOAD_BYTES = 64 * 1024

        // Every notification is framed so the receiver can join mid-stream and
        // resynchronise on the next header, which is what makes retransmission work.
        private const val FRAME_HEADER: Byte = 0x01
        private const val FRAME_DATA: Byte = 0x02

        /**
         * Last-resort trigger for a central that never negotiates an MTU at all.
         * It must stay well clear of a real MTU exchange, which takes ~3s when an
         * Android 17 phone is the central - at 2.5s this fired first and chunked
         * the whole payload at the 23-byte default (211 frames instead of 24).
         * The real triggers are the readiness read and [POST_MTU_PUSH_MS].
         */
        private const val PUSH_SETTLE_MS = 8_000L

        /**
         * Once the MTU is known, how long to give the central to finish discovery
         * and register for notifications before pushing. Measured at ~40ms on a
         * Pixel 8, so this is generous. Scheduling from the MTU exchange rather
         * than blindly from connect is what keeps the first attempt from chunking
         * at the 23-byte default.
         */
        private const val POST_MTU_PUSH_MS = 500L

        /** Release the client regardless if the disconnect callback never lands. */
        private const val CLOSE_FALLBACK_MS = 2_000L

        /**
         * Keep the link up briefly after the last frame is confirmed. The ATT
         * confirmation is generated by the receiver's stack before its app has
         * necessarily processed the frame, so tearing down instantly could make
         * the receiver see a disconnect while it still believes the transfer is
         * incomplete.
         */
        private const val LINGER_MS = 1_500L

        /**
         * If the receiver hasn't disconnected (its only way of confirming) this
         * long after a full push, send the whole payload again. An Android 17
         * central cannot signal readiness at all - every app-initiated GATT
         * operation it makes is silently dropped - so the sender cannot wait to be
         * told, and simply repeats until the receiver confirms or we time out.
         *
         * Must exceed the ~5s link supervision timeout: the receiver's disconnect
         * is its only way to confirm, and the peer does not observe it for about
         * four seconds, so a shorter retry retransmits a payload that already
         * arrived.
         */
        private const val PUSH_RETRY_MS = 6_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager?.adapter

    private var mtu = DEFAULT_MTU
    private var serviceUuid: UUID? = null

    private val transferTimeout = Runnable { onTransferTimeout() }
    private val pushSettle = Runnable { beginPush() }
    private val linger = Runnable { stopInternal() }
    private var delivered = false

    /**
     * Whether the receiver proved its app registered for notifications, by
     * issuing the readiness read. Only then does an indication confirmation
     * amount to app-level delivery - the ATT layer confirms and discards frames
     * for handles no app has registered. Android 17 centrals can never set this.
     */
    private var readyProven = false

    /**
     * [readyProven] snapshotted when the current attempt started. The readiness
     * read can land mid-push; sampling it live would send early frames
     * unacknowledged and later ones as indications, then wrongly report the whole
     * attempt as acknowledged by a registered receiver.
     */
    private var attemptConfirmed = false
    private val closeFallback = Runnable { stopInternal() }
    private val pushRetry = Runnable { beginPush() }
    private var attempt = 0

    // --- sender (peripheral) state ---
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var payloadChar: BluetoothGattCharacteristic? = null
    private var connectedCentral: BluetoothDevice? = null
    private var pendingBlob: ByteArray? = null
    private val sendQueue = ArrayDeque<ByteArray>()
    private var pushing = false
    private var allSent = false

    // --- receiver (central) state ---
    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var gatt: BluetoothGatt? = null
    private var expectingHeader = true
    private var expectedLen = 0
    private val inbox = ByteArrayOutputStream()
    private var assembled = false

    fun isAvailable(): Boolean {
        return try {
            val a = adapter ?: return false
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return false
            a.isEnabled
        } catch (e: SecurityException) {
            false
        }
    }

    // ------------------------------------------------------------------ sender

    /** Advertise [uuidString] and push [blob] to the first central that connects. */
    fun startSending(uuidString: String, blob: ByteArray) {
        stopInternal()
        val a = adapter ?: return sendError("bluetooth unavailable")
        val adv = a.bluetoothLeAdvertiser
            ?: return sendError("BLE advertising is not supported on this device")
        val uuid = parseUuid(uuidString) ?: return sendError("invalid rendezvous uuid")
        logd("startSending uuid=$uuid blob=${blob.size}B")
        serviceUuid = uuid
        advertiser = adv
        pendingBlob = blob

        val server = manager?.openGattServer(context, serverCallback)
            ?: return sendError("could not open GATT server")
        gattServer = server

        val service = BluetoothGattService(uuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val payload = BluetoothGattCharacteristic(
            CHAR_PAYLOAD_UUID,
            // READ: the receiver reads this once it has registered, and that read
            // is what tells us it is safe to start pushing - a read rather than a
            // write because client writes are broken on Android 17.
            //
            // INDICATE: frames are sent as indications, not notifications. The
            // receiver's ATT layer confirms each one automatically, with no app
            // involvement, which is the only end-to-end delivery signal available
            // when the peer cannot make any app-initiated GATT call at all.
            BluetoothGattCharacteristic.PROPERTY_READ or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                BluetoothGattCharacteristic.PROPERTY_INDICATE,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        // Declared for correctness. The receiver never writes it - Android's GATT
        // server does not gate notifyCharacteristicChanged on the CCCD, and a
        // client write is precisely the operation this design avoids.
        payload.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            )
        )
        service.addCharacteristic(payload)
        payloadChar = payload

        main.postDelayed(transferTimeout, TRANSFER_TIMEOUT_MS)
        // Advertising starts in onServiceAdded, so a central can never connect
        // and find an empty GATT server.
        server.addService(service)
    }

    private fun startAdvertisingInternal() {
        val adv = advertiser ?: return
        val uuid = serviceUuid ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(uuid))
            .build()
        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                logd("advertising started")
            }

            override fun onStartFailure(errorCode: Int) {
                sendError("advertise failed: $errorCode")
            }
        }
        advertiseCallback = cb
        adv.startAdvertising(settings, data, cb)
        sendStatus("advertising")
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (service.uuid != serviceUuid) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                startAdvertisingInternal()
            } else {
                sendError("failed to register GATT service: $status")
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            logd("server conn newState=$newState status=$status allSent=$allSent")
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connectedCentral = device
                    // Some stacks corrupt an active connection while still
                    // advertising, and we only ever serve one central.
                    stopAdvertising()
                    sendStatus("connected")
                    main.postDelayed(pushSettle, PUSH_SETTLE_MS)
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (device != connectedCentral) return
                    connectedCentral = null
                    // The receiver disconnects once it has the whole payload -
                    // that is the delivery signal, since acknowledging it in-band
                    // would require a client write.
                    if (allSent) {
                        // Backstop: normally reportDelivered() has already fired on
                        // the last indication's confirmation.
                        reportDelivered("central disconnected after full payload")
                    } else if (pushing) {
                        sendError("receiver disconnected mid-transfer (status=$status)")
                        stopInternal()
                    }
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            logd("server mtu=$mtu")
            this@BleTapController.mtu = mtu
            // Do not push from here: the central negotiates the MTU *before* it
            // discovers services and registers for notifications, so anything sent
            // now lands on the floor. But this is the right moment to time from -
            // re-arm the settle so the first attempt chunks at the real MTU rather
            // than the 23-byte default.
            if (!pushing && !allSent) {
                main.removeCallbacks(pushSettle)
                main.postDelayed(pushSettle, POST_MTU_PUSH_MS)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, ByteArray(0))
            if (characteristic.uuid != CHAR_PAYLOAD_UUID) return
            // Fast path: a central that can still issue reads is telling us it is
            // ready, so skip the settle. Android 17 centrals never get here.
            logd("receiver read the payload characteristic: ready, starting push")
            readyProven = true
            if (!pushing) {
                main.removeCallbacks(pushSettle)
                beginPush()
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                sendError("notification failed: $status")
                stopInternal()
                return
            }
            pushNext()
        }
    }

    /**
     * The payload is confirmed delivered. Idempotent: the last indication's
     * confirmation and the receiver's subsequent disconnect can both land here.
     */
    private fun reportDelivered(why: String) {
        if (delivered) return
        delivered = true
        logd("$why -> delivered")
        main.removeCallbacks(transferTimeout)
        main.removeCallbacks(pushRetry)
        main.removeCallbacks(pushSettle)
        sendStatus("confirmed")
        main.postDelayed(linger, LINGER_MS)
    }

    /** Chunk the blob for the negotiated MTU and start streaming it. */
    private fun beginPush() {
        if (pushing) return
        val blob = pendingBlob ?: return sendError("no payload to send")
        if (connectedCentral == null) return sendError("no central connected")
        pushing = true
        allSent = false
        attempt++
        attemptConfirmed = readyProven
        sendQueue.clear()

        val header = ByteArray(6)
        header[0] = FRAME_HEADER
        header[1] = HEADER_VERSION
        header[2] = ((blob.size ushr 24) and 0xFF).toByte()
        header[3] = ((blob.size ushr 16) and 0xFF).toByte()
        header[4] = ((blob.size ushr 8) and 0xFF).toByte()
        header[5] = (blob.size and 0xFF).toByte()
        sendQueue.addLast(header)

        // One byte of every notification is the frame tag.
        val frameSize = (mtu - ATT_NOTIFY_OVERHEAD).coerceAtMost(MAX_SAFE_CHUNK).coerceAtLeast(20)
        val dataSize = frameSize - 1
        var i = 0
        while (i < blob.size) {
            val end = minOf(i + dataSize, blob.size)
            val frame = ByteArray(end - i + 1)
            frame[0] = FRAME_DATA
            blob.copyInto(frame, 1, i, end)
            sendQueue.addLast(frame)
            i = end
        }
        logd(
            "beginPush attempt=$attempt blob=${blob.size}B mtu=$mtu dataSize=$dataSize " +
                "frames=${sendQueue.size} mode=${if (attemptConfirmed) "indicate" else "notify"}"
        )
        sendStatus("writing")
        pushNext()
    }

    /** Send the next queued chunk; each is paced by onNotificationSent. */
    private fun pushNext() {
        val server = gattServer ?: return
        val device = connectedCentral ?: return
        val ch = payloadChar ?: return
        val chunk = sendQueue.pollFirst()
        if (chunk == null) {
            allSent = true
            pushing = false
            if (attemptConfirmed) {
                // Every frame was confirmed by the receiver's ATT layer AND its app
                // proved it had registered before this attempt began, so this is
                // real delivery. Skip the ~4.2s supervision timeout.
                reportDelivered("attempt $attempt acknowledged by a registered receiver")
            } else {
                // Frames were confirmed, but the receiver never proved its app was
                // listening - and the ATT layer confirms then discards frames for
                // unregistered handles. Not enough to claim delivery of money. Fall
                // back to the disconnect, which only happens once the app has
                // actually assembled the payload.
                logd("attempt $attempt acknowledged, but readiness unproven - awaiting disconnect")
                sendStatus("sent")
                main.postDelayed(pushRetry, PUSH_RETRY_MS)
            }
            return
        }
        val ok = notifyChunk(server, device, ch, chunk)
        if (!ok) {
            sendError("could not queue notification")
            stopInternal()
        }
    }

    @Suppress("DEPRECATION")
    private fun notifyChunk(
        server: BluetoothGattServer,
        device: BluetoothDevice,
        ch: BluetoothGattCharacteristic,
        value: ByteArray,
    ): Boolean {
        // Indications only when they buy something. confirm = true makes
        // onNotificationSent fire on the receiver's ATT confirmation rather than
        // on local buffer availability, which lets us declare delivery on the last
        // frame instead of waiting out the ~4.2s supervision timeout - but each
        // one costs a round trip (~131ms measured, vs ~1.8ms for a notification).
        //
        // That trade only pays off when the confirmation actually means delivery,
        // i.e. when the receiver proved its app had registered. Otherwise we are
        // waiting for the disconnect either way, so push fast and unacknowledged.
        val confirm = attemptConfirmed
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val res = server.notifyCharacteristicChanged(device, ch, confirm, value)
            if (res != BluetoothStatusCodes.SUCCESS) logd("notify/indicate code=$res")
            res == BluetoothStatusCodes.SUCCESS
        } else {
            ch.value = value
            server.notifyCharacteristicChanged(device, ch, confirm)
        }
    }

    // ---------------------------------------------------------------- receiver

    /** Scan for [uuidString], connect, and receive the pushed payload. */
    fun startReceiving(uuidString: String) {
        stopInternal()
        val a = adapter ?: return sendError("bluetooth unavailable")
        val s = a.bluetoothLeScanner ?: return sendError("BLE scanning not supported")
        val uuid = parseUuid(uuidString) ?: return sendError("invalid rendezvous uuid")
        logd("startReceiving uuid=$uuid")
        serviceUuid = uuid
        resetInbox()

        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(uuid)).build())
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                scanner?.stopScan(this)
                scanCallback = null
                connectTo(result.device)
            }

            override fun onScanFailed(errorCode: Int) {
                sendError("scan failed: $errorCode")
            }
        }
        scanner = s
        scanCallback = cb
        s.startScan(filters, settings, cb)
        main.postDelayed(transferTimeout, TRANSFER_TIMEOUT_MS)
        sendStatus("scanning")
    }

    private fun connectTo(device: BluetoothDevice) {
        sendStatus("connecting")
        gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, gattCallback)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            logd("client conn newState=$newState status=$status assembled=$assembled")
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    sendStatus("connected")
                    // Issue GATT operations from the main thread rather than the
                    // binder callback thread they arrived on.
                    main.post { gatt?.requestMtu(517) }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (assembled) {
                        // Our own terminate completing; safe to release now.
                        main.removeCallbacks(closeFallback)
                        main.post { stopInternal() }
                    } else {
                        sendError("sender disconnected before the payload arrived")
                    }
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            this@BleTapController.mtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else DEFAULT_MTU
            logd("client mtu=$mtu status=$status using=${this@BleTapController.mtu}")
            main.post { gatt?.discoverServices() }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val uuid = serviceUuid ?: return sendError("no rendezvous uuid")
            val service = g.getService(uuid) ?: return sendError("rendezvous service not found")
            val ch = service.getCharacteristic(CHAR_PAYLOAD_UUID)
                ?: return sendError("payload characteristic not found")
            // Local registration only - this generates no ATT traffic. We
            // deliberately do NOT write the CCCD: that is a client write, the one
            // operation that is broken on Android 17, and the sender notifies
            // unconditionally so no subscription is needed.
            val ok = g.setCharacteristicNotification(ch, true)
            logd("services discovered status=$status setNotification=$ok")
            if (!ok) return sendError("could not register for notifications")
            sendStatus("receiving")
            // Announce readiness. Only once this read lands does the sender start
            // pushing, so no chunk can arrive before we are listening.
            main.post {
                val gg = gatt ?: return@post
                val issued = gg.readCharacteristic(ch)
                logd("readiness read issued=$issued")
                if (!issued) sendError("could not signal readiness to the sender")
            }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (characteristic.uuid != CHAR_PAYLOAD_UUID) return
            handleInbound(value)
        }

        // Pre-33 notification callback; the 3-arg overload above supersedes it.
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            if (characteristic.uuid != CHAR_PAYLOAD_UUID) return
            handleInbound(characteristic.value ?: return)
        }
    }

    /**
     * Every notification is framed, so joining part-way through a push is
     * survivable: data frames received before a header are discarded, and the
     * next header resets collection. The sender retransmits until we confirm by
     * disconnecting, so a missed first attempt costs a retry, not the transfer.
     */
    private fun handleInbound(value: ByteArray) {
        if (assembled || value.isEmpty()) return
        when (value[0]) {
            FRAME_HEADER -> {
                if (value.size < 6 || value[1] != HEADER_VERSION) {
                    logd("malformed header frame size=${value.size}, ignoring")
                    return
                }
                val len = ((value[2].toInt() and 0xFF) shl 24) or
                    ((value[3].toInt() and 0xFF) shl 16) or
                    ((value[4].toInt() and 0xFF) shl 8) or
                    (value[5].toInt() and 0xFF)
                if (len <= 0 || len > MAX_PAYLOAD_BYTES) {
                    logd("implausible header length=$len, ignoring")
                    return
                }
                expectedLen = len
                expectingHeader = false
                inbox.reset()
                logd("header ok expectedLen=$expectedLen")
            }
            FRAME_DATA -> {
                // No header yet: we joined mid-push. Wait for the retransmission.
                if (expectingHeader) return
                inbox.write(value, 1, value.size - 1)
                logd("inbound ${value.size - 1}B total=${inbox.size()}/$expectedLen")
                if (inbox.size() >= expectedLen) {
                    val full = inbox.toByteArray()
                    val blob = if (full.size > expectedLen) full.copyOfRange(0, expectedLen) else full
                    assembled = true
                    main.removeCallbacks(transferTimeout)
                    logd("assembled ${blob.size}B, disconnecting to confirm")
                    sendReceived(blob)
                    // Disconnecting is the delivery signal the sender waits for, so
                    // it needs to be a clean terminate: disconnect and let the
                    // callback close us. Calling close() straight after disconnect()
                    // suppresses the terminate and the sender only notices ~4s later
                    // on supervision timeout, by which point it has retransmitted.
                    main.post {
                        gatt?.disconnect()
                        main.postDelayed(closeFallback, CLOSE_FALLBACK_MS)
                    }
                }
            }
            else -> logd("unknown frame tag=${value[0]}, ignoring")
        }
    }

    // ------------------------------------------------------------------ common

    fun stop() {
        stopInternal()
        sendStatus("stopped")
    }

    private fun stopAdvertising() {
        try {
            advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (e: Exception) {
            Log.w(TAG, "stopAdvertising: ${e.message}")
        }
        advertiseCallback = null
    }

    private fun stopInternal() {
        main.removeCallbacks(transferTimeout)
        main.removeCallbacks(pushSettle)
        main.removeCallbacks(pushRetry)
        main.removeCallbacks(closeFallback)
        main.removeCallbacks(linger)
        delivered = false
        readyProven = false
        attemptConfirmed = false
        attempt = 0

        try {
            scanCallback?.let { scanner?.stopScan(it) }
        } catch (e: Exception) {
            Log.w(TAG, "stopScan: ${e.message}")
        }
        scanCallback = null
        scanner = null

        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (e: Exception) {
            Log.w(TAG, "gatt close: ${e.message}")
        }
        gatt = null

        stopAdvertising()
        advertiser = null

        try {
            gattServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "gattServer close: ${e.message}")
        }
        gattServer = null
        payloadChar = null
        connectedCentral = null

        sendQueue.clear()
        pendingBlob = null
        pushing = false
        allSent = false
        serviceUuid = null
        assembled = false
        resetInbox()
        mtu = DEFAULT_MTU
    }

    private fun onTransferTimeout() {
        logd("transfer timed out pushing=$pushing allSent=$allSent queued=${sendQueue.size} assembled=$assembled")
        sendError("tap transfer timed out")
        stopInternal()
    }

    private fun resetInbox() {
        expectingHeader = true
        expectedLen = 0
        inbox.reset()
    }

    private fun parseUuid(value: String): UUID? = try {
        UUID.fromString(value)
    } catch (e: IllegalArgumentException) {
        null
    }

    private fun send(map: Map<String, Any?>) = main.post { emit(map) }
    private fun sendStatus(state: String) = send(mapOf("event" to "status", "state" to state))

    /** Log to logcat only (adb logcat -s BleTap). The native BLE trace stays out
     *  of the in-app log so it doesn't flood it during a multi-chunk transfer. */
    private fun logd(message: String) {
        Log.i(TAG, message)
    }
    private fun sendReceived(blob: ByteArray) = send(mapOf("event" to "received", "data" to blob))
    private fun sendError(message: String) {
        Log.w(TAG, message)
        main.removeCallbacks(transferTimeout)
        main.removeCallbacks(pushSettle)
        main.removeCallbacks(pushRetry)
        send(mapOf("event" to "error", "message" to message))
    }
}
