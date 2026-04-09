package com.example.demo_ai_even.utils

object ByteUtil {

    fun byteToHexArray(bytes: ByteArray?): String {
        if (bytes == null) {
            return ""
        }
        val sb = StringBuilder()
        for (b in bytes) {
            sb.append(byteToHex(b))
        }
        return sb.toString()
    }

    private fun byteToHex(b: Byte): String = String.format("%02x ", b)

}