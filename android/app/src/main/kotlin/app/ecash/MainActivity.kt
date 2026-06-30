package org.fedimint.app.master

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.nfc.NfcAdapter
import android.nfc.cardemulation.CardEmulation
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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
    }

    override fun onResume() {
        super.onResume()
        nfcAdapter?.enableForegroundDispatch(
            this,
            nfcPendingIntent,
            nfcIntentFilters,
            null,
        )
    }

    override fun onPause() {
        super.onPause()
        nfcAdapter?.disableForegroundDispatch(this)
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
