package org.fedimint.app.master

import android.nfc.cardemulation.HostApduService
import android.os.Bundle
import android.util.Log

/**
 * Emulates an NFC Forum Type 4 Tag (NDEF) so a reader phone can pick the
 * current Lightning invoice off this device via a tap.
 *
 * Protocol reference: NFC Forum Type 4 Tag Operation Specification, Appendix E
 * "Example Command Flow". We respond to four commands:
 *   1. SELECT NDEF Tag Application (by AID D2760000850101)
 *   2. SELECT file by ID (CC = E103, NDEF = E104)
 *   3. READ BINARY  (from the selected file at a given offset)
 *
 * APDUs are matched by header (CLA/INS/P1/P2 + Lc payload) and the trailing
 * `Le` byte is ignored, so we accept variations between reader stacks.
 */
class EcashHceService : HostApduService() {

    companion object {
        private const val TAG = "EcashHce"

        // Set by Flutter via the MethodChannel in MainActivity. When non-null, this
        // service serves the bytes as a Type 4 NDEF file.
        @Volatile
        var ndefMessage: ByteArray? = null

        private val SW_OK = byteArrayOf(0x90.toByte(), 0x00.toByte())
        private val SW_NOT_FOUND = byteArrayOf(0x6A.toByte(), 0x82.toByte())

        // "D2760000850101" — NDEF Type 4 Tag Application
        private val NDEF_AID = byteArrayOf(
            0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01,
        )
        private val CC_FILE_ID = byteArrayOf(0xE1.toByte(), 0x03)
        private val NDEF_FILE_ID = byteArrayOf(0xE1.toByte(), 0x04)

        // Capability Container: 15 bytes pointing the reader at the NDEF file (E104).
        private val CC_CONTENT = byteArrayOf(
            0x00, 0x0F,                         // CCLEN = 15
            0x20,                                // Mapping Version 2.0
            0x00, 0xF6.toByte(),                 // MLe = 246 (max R-APDU data length)
            0x00, 0xF6.toByte(),                 // MLc = 246 (max C-APDU data length)
            0x04,                                // NDEF File Control TLV: tag
            0x06,                                // ...length
            0xE1.toByte(), 0x04,                 // ...NDEF file ID
            0x04, 0x00,                          // ...max NDEF size = 1024 bytes
            0x00,                                // read access: open
            0xFF.toByte(),                       // write access: disabled
        )
    }

    private enum class Selected { NONE, CC, NDEF }
    private var selected = Selected.NONE

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "service onCreate (ndefMessage size=${ndefMessage?.size})")
    }

    private fun reply(label: String, response: ByteArray): ByteArray {
        Log.i(
            TAG,
            "$label → ${response.joinToString("") { "%02X".format(it) }}",
        )
        return response
    }

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        Log.i(
            TAG,
            "processCommandApdu len=${commandApdu?.size} bytes=${commandApdu?.joinToString("") { "%02X".format(it) }}",
        )
        if (commandApdu == null || commandApdu.size < 4) return reply("BAD len", SW_NOT_FOUND)

        val cla = commandApdu[0]
        val ins = commandApdu[1]
        val p1 = commandApdu[2]
        val p2 = commandApdu[3]

        // SELECT — 00 A4 ...
        if (cla == 0x00.toByte() && ins == 0xA4.toByte()) {
            // SELECT BY NAME (AID): P1=04 P2=00, data = AID
            if (p1 == 0x04.toByte() && p2 == 0x00.toByte() && commandApdu.size >= 5) {
                val lc = commandApdu[4].toInt() and 0xFF
                if (commandApdu.size >= 5 + lc && lc == NDEF_AID.size) {
                    val aid = commandApdu.copyOfRange(5, 5 + lc)
                    if (aid.contentEquals(NDEF_AID)) {
                        selected = Selected.NONE
                        return reply("SELECT AID ok", SW_OK)
                    }
                }
                return reply("SELECT AID not found", SW_NOT_FOUND)
            }
            // SELECT BY FILE ID: P1=00 P2=0C, data = 2-byte file ID
            if (p1 == 0x00.toByte() && p2 == 0x0C.toByte() && commandApdu.size >= 7) {
                val lc = commandApdu[4].toInt() and 0xFF
                if (lc == 2) {
                    val fid = commandApdu.copyOfRange(5, 7)
                    when {
                        fid.contentEquals(CC_FILE_ID) -> {
                            selected = Selected.CC
                            return reply("SELECT CC ok", SW_OK)
                        }
                        fid.contentEquals(NDEF_FILE_ID) -> {
                            selected = Selected.NDEF
                            return reply("SELECT NDEF ok", SW_OK)
                        }
                    }
                }
                return reply("SELECT file not found", SW_NOT_FOUND)
            }
            return reply("SELECT unknown variant", SW_NOT_FOUND)
        }

        // READ BINARY — 00 B0 P1 P2 Le
        if (cla == 0x00.toByte() && ins == 0xB0.toByte()) {
            val offset = ((p1.toInt() and 0xFF) shl 8) or (p2.toInt() and 0xFF)
            val le = if (commandApdu.size >= 5) commandApdu[4].toInt() and 0xFF else 0

            val file = when (selected) {
                Selected.CC -> CC_CONTENT
                Selected.NDEF -> {
                    val msg = ndefMessage ?: return reply("READ no NDEF message", SW_NOT_FOUND)
                    // The NDEF file is NLEN (2 bytes, big-endian) followed by the message.
                    val nlen = msg.size
                    byteArrayOf(((nlen ushr 8) and 0xFF).toByte(), (nlen and 0xFF).toByte()) + msg
                }
                Selected.NONE -> return reply("READ no selected file", SW_NOT_FOUND)
            }

            if (offset >= file.size) return reply("READ offset OOB", SW_NOT_FOUND)
            val length = minOf(if (le == 0) 256 else le, file.size - offset)
            return reply(
                "READ ${selected.name} offset=$offset le=$le → ${length}B",
                file.copyOfRange(offset, offset + length) + SW_OK,
            )
        }

        return reply("unknown CLA/INS", SW_NOT_FOUND)
    }

    override fun onDeactivated(reason: Int) {
        Log.i(TAG, "onDeactivated reason=$reason")
        selected = Selected.NONE
    }
}
