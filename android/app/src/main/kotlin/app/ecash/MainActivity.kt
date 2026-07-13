package org.fedimint.app.master

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.cardemulation.CardEmulation
import android.nfc.tech.Ndef
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        init {
            // Load the Rust library through the JVM so its `JNI_OnLoad` runs and
            // initializes `ndk_context`. Native networking crates used by
            // fedimint's iroh transport (hickory-resolver for DNS, netdev) read
            // the Android system network config through `ndk_context`; without it
            // the first federation DNS lookup panics with
            // "android context was not initialized". Flutter later dlopen()s the
            // same .so from Dart, which just reuses this already-loaded library.
            System.loadLibrary("ecashapp")
        }
    }

    private val hceComponent by lazy {
        ComponentName(this, EcashHceService::class.java)
    }

    private var nfcAdapter: NfcAdapter? = null
    private var nfcPendingIntent: PendingIntent? = null
    private var nfcIntentFilters: Array<IntentFilter>? = null

    private var bleController: BleTapController? = null
    private var bleEventSink: EventChannel.EventSink? = null

    private var nfcTapEventSink: EventChannel.EventSink? = null
    private var readerModeActive = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Foreground dispatch routes NFC taps for payment URIs straight to
        // this activity's onNewIntent while it's in the foreground. Without
        // this, the OS tag dispatcher would launch the activity via
        // FLAG_ACTIVITY_NEW_TASK and the user sees a relaunch even with
        // singleTop. The manifest NDEF intent filter still covers cold start.
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)
        val selfIntent = Intent(this, javaClass).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        nfcPendingIntent = PendingIntent.getActivity(
            this,
            0,
            selfIntent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        nfcIntentFilters = arrayOf(
            IntentFilter(NfcAdapter.ACTION_NDEF_DISCOVERED).apply {
                addDataScheme("lightning")
                addDataScheme("lnurl")
                addDataScheme("bitcoin")
                addDataScheme("lnurlp")
            },
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ecashapp/nfc_hce")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> {
                        val pm = applicationContext.packageManager
                        val hasHce = pm.hasSystemFeature(
                            PackageManager.FEATURE_NFC_HOST_CARD_EMULATION,
                        )
                        val enabled = NfcAdapter.getDefaultAdapter(applicationContext)
                            ?.isEnabled ?: false
                        Log.i("EcashHce", "isAvailable hasHce=$hasHce enabled=$enabled")
                        result.success(hasHce && enabled)
                    }
                    "start" -> {
                        val payload = call.argument<String>("payload")
                        if (payload == null) {
                            result.error("missing_payload", "payload required", null)
                        } else {
                            EcashHceService.ndefMessage = buildNdefUriRecord(payload)
                            val preferred = setPreferredHce(true)
                            Log.i(
                                "EcashHce",
                                "start payload.len=${payload.length} ndef.size=${EcashHceService.ndefMessage?.size} preferred=$preferred",
                            )
                            result.success(null)
                        }
                    }
                    "stop" -> {
                        EcashHceService.ndefMessage = null
                        val preferred = setPreferredHce(false)
                        Log.i("EcashHce", "stop preferred=$preferred")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // BLE "tap to send" transport (Phase 2). Events stream to Dart over an
        // EventChannel; the controller posts them on the main thread already.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "ecashapp/ble_tap/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    bleEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    bleEventSink = null
                }
            })

        val ble = BleTapController(applicationContext) { event -> bleEventSink?.success(event) }
        bleController = ble
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ecashapp/ble_tap")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(ble.isAvailable())
                    "startReceiver" -> {
                        val uuid = call.argument<String>("uuid")
                        if (uuid == null) {
                            result.error("missing_uuid", "uuid required", null)
                        } else {
                            ble.startReceiver(uuid)
                            result.success(null)
                        }
                    }
                    "sendToPeer" -> {
                        val uuid = call.argument<String>("uuid")
                        val blob = call.argument<ByteArray>("blob")
                        if (uuid == null || blob == null) {
                            result.error("missing_args", "uuid and blob required", null)
                        } else {
                            ble.sendToPeer(uuid, blob)
                            result.success(null)
                        }
                    }
                    "stop" -> {
                        ble.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // NFC reader mode for the "tap to send" handshake (Phase 3). The sender
        // reads the receiver's rendezvous (ephemeral pubkey + BLE service UUID)
        // off an emulated NDEF tag. Reader mode and foreground dispatch are
        // mutually exclusive, so `readerModeActive` gates onResume/onPause.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "ecashapp/nfc_tap/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    nfcTapEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    nfcTapEventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ecashapp/nfc_tap")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startReader" -> {
                        val adapter = nfcAdapter
                        if (adapter == null) {
                            result.error("no_nfc", "NFC unavailable", null)
                        } else {
                            readerModeActive = true
                            adapter.disableForegroundDispatch(this)
                            enableReaderModeInternal(adapter)
                            result.success(null)
                        }
                    }
                    "stopReader" -> {
                        readerModeActive = false
                        nfcAdapter?.disableReaderMode(this)
                        nfcAdapter?.enableForegroundDispatch(
                            this, nfcPendingIntent, nfcIntentFilters, null,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        bleController?.stop()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        val adapter = nfcAdapter ?: return
        if (readerModeActive) {
            enableReaderModeInternal(adapter)
        } else {
            adapter.enableForegroundDispatch(this, nfcPendingIntent, nfcIntentFilters, null)
        }
    }

    override fun onPause() {
        super.onPause()
        val adapter = nfcAdapter ?: return
        if (readerModeActive) {
            adapter.disableReaderMode(this)
        } else {
            adapter.disableForegroundDispatch(this)
        }
    }

    private fun enableReaderModeInternal(adapter: NfcAdapter) {
        val flags = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_NFC_V
        adapter.enableReaderMode(this, { tag -> if (tag != null) onTagRead(tag) }, flags, null)
    }

    /**
     * Read the receiver's rendezvous URI (`ecashtap:<base64>`) off an emulated
     * NDEF tag and forward it to Dart, which decodes the pubkey + BLE UUID.
     */
    private fun onTagRead(tag: Tag) {
        val ndef = Ndef.get(tag)
        if (ndef == null) {
            emitNfcTap(mapOf("event" to "error", "message" to "tag is not NDEF"))
            return
        }
        try {
            ndef.connect()
            val uri = ndef.ndefMessage?.records?.firstOrNull()?.toUri()?.toString()
            if (uri != null) {
                emitNfcTap(mapOf("event" to "read", "uri" to uri))
            } else {
                emitNfcTap(mapOf("event" to "error", "message" to "no URI record on tag"))
            }
        } catch (e: Exception) {
            emitNfcTap(mapOf("event" to "error", "message" to (e.message ?: "NFC read failed")))
        } finally {
            try {
                ndef.close()
            } catch (e: Exception) {
                Log.w("NfcTap", "ndef close: ${e.message}")
            }
        }
    }

    private fun emitNfcTap(event: Map<String, Any?>) {
        runOnUiThread { nfcTapEventSink?.success(event) }
    }

    /**
     * Tell the system to route AIDs we claim to our service while our activity
     * is in the foreground. Without this, category="other" services can be
     * shadowed by another app on the device that also claims the AID.
     */
    private fun setPreferredHce(preferred: Boolean): Boolean {
        val nfcAdapter = NfcAdapter.getDefaultAdapter(this) ?: return false
        val cardEmulation = CardEmulation.getInstance(nfcAdapter)
        return if (preferred) {
            cardEmulation.setPreferredService(this, hceComponent)
        } else {
            cardEmulation.unsetPreferredService(this)
            true
        }
    }

    /**
     * Builds a single-record NDEF message: TNF=Well Known, Type='U' (URI),
     * prefix byte 0x00 (no abbreviation, full URI in payload). Android's NFC
     * dispatcher fires ACTION_NDEF_DISCOVERED for well-known URI records,
     * keyed on the URI's scheme — which matches our `lightning:` intent
     * filter on MainActivity (cold start) and our foreground dispatch
     * IntentFilters (warm start). Uses short-record form when payload fits
     * in one byte, long form otherwise — Lightning invoices can exceed 255 bytes.
     */
    private fun buildNdefUriRecord(uri: String): ByteArray {
        val uriBytes = uri.toByteArray(Charsets.UTF_8)
        // URI record payload = 1-byte prefix code + URI bytes. 0x00 = no prefix.
        val payload = ByteArray(1 + uriBytes.size).also {
            it[0] = 0x00
            System.arraycopy(uriBytes, 0, it, 1, uriBytes.size)
        }

        val shortRecord = payload.size < 256
        // Header: MB=1, ME=1, CF=0, SR=shortRecord, IL=0, TNF=001 (Well Known)
        val header = (if (shortRecord) 0xD1 else 0xC1).toByte()
        val typeByte = 0x55.toByte() // 'U'
        val out = ArrayList<Byte>(payload.size + 8)
        out.add(header)
        out.add(0x01) // type length
        if (shortRecord) {
            out.add(payload.size.toByte())
        } else {
            val n = payload.size
            out.add(((n ushr 24) and 0xFF).toByte())
            out.add(((n ushr 16) and 0xFF).toByte())
            out.add(((n ushr 8) and 0xFF).toByte())
            out.add((n and 0xFF).toByte())
        }
        out.add(typeByte)
        for (b in payload) out.add(b)
        return out.toByteArray()
    }
}
