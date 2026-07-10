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
import java.util.UUID

/**
 * Native BLE transport for "tap to send" ecash (Phase 3).
 *
 * The rendezvous service UUID and the receiver's ephemeral public key are
 * exchanged over NFC (see MainActivity's `ecashapp/nfc_tap` reader + the HCE
 * publish path). BLE then only carries the already-encrypted blob:
 *   - Receiver advertises the per-session [serviceUuid] and runs a GATT server.
 *   - Sender scans for that UUID, connects **without bonding**, and streams the
 *     blob it encrypted for the NFC-delivered pubkey.
 *
 * All characteristics are unencrypted at the link layer (no pairing); the
 * payload is already encrypted at the app layer (rust/ecashapp/src/tap_transfer.rs).
 *
 * Events emitted to Dart via [emit] (posted to the main thread):
 *   {event:"status", state:"advertising|scanning|connecting|connected|writing|sent|confirmed|stopped"}
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

        // Fixed characteristic UUIDs living inside the per-session rendezvous service.
        private val CHAR_INBOX_UUID: UUID = UUID.fromString("e3c0f2a1-0b7d-4c6e-9a2f-1d5b0e7a0003")
        private val CHAR_STATUS_UUID: UUID = UUID.fromString("e3c0f2a1-0b7d-4c6e-9a2f-1d5b0e7a0004")
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        private const val HEADER_VERSION: Byte = 1
        private const val DEFAULT_MTU = 23
        private const val ATT_WRITE_OVERHEAD = 3
        private const val STATUS_DONE: Byte = 0x01
        private const val STATUS_ERROR: Byte = 0x02
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager?.adapter

    private var mtu = DEFAULT_MTU

    // Rendezvous service UUID for the current transfer (from NFC), used by both roles.
    private var serviceUuid: UUID? = null

    // --- receiver (peripheral) state ---
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var statusChar: BluetoothGattCharacteristic? = null
    private var connectedCentral: BluetoothDevice? = null
    private var expectingHeader = true
    private var expectedLen = 0
    private val inbox = ByteArrayOutputStream()

    // --- sender (central) state ---
    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var gatt: BluetoothGatt? = null
    private var inboxChar: BluetoothGattCharacteristic? = null
    private val writeQueue = ArrayDeque<ByteArray>()
    private var pendingBlob: ByteArray? = null

    /** BLE present + enabled. Peripheral (advertise) support is checked in [startReceiver]. */
    fun isAvailable(): Boolean {
        return try {
            val a = adapter ?: return false
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return false
            a.isEnabled
        } catch (e: SecurityException) {
            false
        }
    }

    // ---------------------------------------------------------------- receiver

    fun startReceiver(uuidString: String) {
        stopInternal()
        val a = adapter ?: return sendError("bluetooth unavailable")
        val adv = a.bluetoothLeAdvertiser
            ?: return sendError("BLE advertising is not supported on this device")
        val uuid = parseUuid(uuidString) ?: return sendError("invalid rendezvous uuid")
        serviceUuid = uuid
        advertiser = adv
        resetInbox()

        val server = manager?.openGattServer(context, serverCallback)
            ?: return sendError("could not open GATT server")
        gattServer = server

        val service = BluetoothGattService(uuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(
            BluetoothGattCharacteristic(
                CHAR_INBOX_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
        )
        val status = BluetoothGattCharacteristic(
            CHAR_STATUS_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        status.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            )
        )
        service.addCharacteristic(status)
        statusChar = status
        // Advertising starts once the service is registered (onServiceAdded), so
        // a central can never connect and find an empty GATT server.
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
                Log.i(TAG, "advertising started")
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
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connectedCentral = device
                    resetInbox()
                    sendStatus("connected")
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (device == connectedCentral) connectedCentral = null
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            this@BleTapController.mtu = mtu
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            val ok = characteristic.uuid == CHAR_INBOX_UUID
            if (ok) handleInbound(value)
            if (responseNeeded) {
                val gattStatus = if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE
                gattServer?.sendResponse(device, requestId, gattStatus, offset, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            // Accept the central's CCCD subscribe/unsubscribe.
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
        }
    }

    private fun handleInbound(value: ByteArray) {
        if (expectingHeader) {
            if (value.size < 5 || value[0] != HEADER_VERSION) {
                sendError("bad transfer header")
                notifyStatus(STATUS_ERROR)
                return
            }
            expectedLen = ((value[1].toInt() and 0xFF) shl 24) or
                ((value[2].toInt() and 0xFF) shl 16) or
                ((value[3].toInt() and 0xFF) shl 8) or
                (value[4].toInt() and 0xFF)
            expectingHeader = false
            inbox.reset()
            return
        }
        inbox.write(value)
        if (inbox.size() >= expectedLen) {
            val full = inbox.toByteArray()
            val blob = if (full.size > expectedLen) full.copyOfRange(0, expectedLen) else full
            sendReceived(blob)
            notifyStatus(STATUS_DONE)
            resetInbox()
        }
    }

    @Suppress("DEPRECATION")
    private fun notifyStatus(code: Byte) {
        val server = gattServer ?: return
        val device = connectedCentral ?: return
        val ch = statusChar ?: return
        val value = byteArrayOf(code)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, ch, false, value)
        } else {
            ch.value = value
            server.notifyCharacteristicChanged(device, ch, false)
        }
    }

    // ------------------------------------------------------------------ sender

    /** Encrypt-then-send: scan for [uuidString], connect, and stream [blob]. */
    fun sendToPeer(uuidString: String, blob: ByteArray) {
        stopInternal()
        val a = adapter ?: return sendError("bluetooth unavailable")
        val s = a.bluetoothLeScanner ?: return sendError("BLE scanning not supported")
        val uuid = parseUuid(uuidString) ?: return sendError("invalid rendezvous uuid")
        serviceUuid = uuid
        pendingBlob = blob

        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(uuid)).build()
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                // One-shot: connect to the first matching advertiser.
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
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                sendStatus("connected")
                g.requestMtu(517)
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            this@BleTapController.mtu = if (status == BluetoothGatt.GATT_SUCCESS) mtu else DEFAULT_MTU
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val uuid = serviceUuid ?: return sendError("no rendezvous uuid")
            val service = g.getService(uuid) ?: return sendError("rendezvous service not found")
            inboxChar = service.getCharacteristic(CHAR_INBOX_UUID)
            val statusCharRemote = service.getCharacteristic(CHAR_STATUS_UUID)
            if (statusCharRemote != null) {
                g.setCharacteristicNotification(statusCharRemote, true)
                val cccd = statusCharRemote.getDescriptor(CCCD_UUID)
                if (cccd != null) {
                    // Serialize GATT ops: subscribe first, then write in onDescriptorWrite.
                    writeDescriptor(g, cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    return
                }
            }
            startWriting(g)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid == CCCD_UUID) startWriting(g)
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (characteristic.uuid != CHAR_INBOX_UUID) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                sendError("chunk write failed: $status")
                return
            }
            writeNext(g)
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (characteristic.uuid == CHAR_STATUS_UUID) handleStatusNotify(value)
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == CHAR_STATUS_UUID) handleStatusNotify(characteristic.value ?: ByteArray(0))
        }
    }

    private fun startWriting(g: BluetoothGatt) {
        val blob = pendingBlob ?: return sendError("no payload to send")
        if (inboxChar == null) return sendError("inbox characteristic unavailable")
        writeQueue.clear()

        val header = ByteArray(5)
        header[0] = HEADER_VERSION
        header[1] = ((blob.size ushr 24) and 0xFF).toByte()
        header[2] = ((blob.size ushr 16) and 0xFF).toByte()
        header[3] = ((blob.size ushr 8) and 0xFF).toByte()
        header[4] = (blob.size and 0xFF).toByte()
        writeQueue.addLast(header)

        val chunkSize = (mtu - ATT_WRITE_OVERHEAD).coerceAtLeast(20)
        var i = 0
        while (i < blob.size) {
            val end = minOf(i + chunkSize, blob.size)
            writeQueue.addLast(blob.copyOfRange(i, end))
            i = end
        }
        sendStatus("writing")
        writeNext(g)
    }

    private fun writeNext(g: BluetoothGatt) {
        val ch = inboxChar ?: return
        val chunk = writeQueue.removeFirstOrNull()
        if (chunk == null) {
            sendStatus("sent")
            return
        }
        writeCharacteristic(g, ch, chunk)
    }

    @Suppress("DEPRECATION")
    private fun writeCharacteristic(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(ch, value, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        } else {
            ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            ch.value = value
            g.writeCharacteristic(ch)
        }
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(descriptor, value)
        } else {
            descriptor.value = value
            g.writeDescriptor(descriptor)
        }
    }

    private fun handleStatusNotify(value: ByteArray) {
        when (value.firstOrNull()) {
            STATUS_DONE -> sendStatus("confirmed")
            STATUS_ERROR -> sendError("receiver reported an error")
        }
    }

    // ------------------------------------------------------------------ common

    fun stop() {
        stopInternal()
        sendStatus("stopped")
    }

    private fun stopInternal() {
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
        inboxChar = null
        writeQueue.clear()
        pendingBlob = null

        try {
            advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (e: Exception) {
            Log.w(TAG, "stopAdvertising: ${e.message}")
        }
        advertiseCallback = null
        advertiser = null

        try {
            gattServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "gattServer close: ${e.message}")
        }
        gattServer = null
        statusChar = null
        connectedCentral = null

        serviceUuid = null
        resetInbox()
        mtu = DEFAULT_MTU
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
    private fun sendReceived(blob: ByteArray) = send(mapOf("event" to "received", "data" to blob))
    private fun sendError(message: String) {
        Log.w(TAG, message)
        send(mapOf("event" to "error", "message" to message))
    }
}
