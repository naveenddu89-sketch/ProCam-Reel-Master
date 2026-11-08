package com.procam.reelmaster.audio

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/**
 * Enumerates real input devices and routes capture to the selected one.
 * Bluetooth uses SCO (narrowband but stable); wired/USB is used as-is.
 */
class AudioRouteManager(context: Context) {

    private val am =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    var selectedId: Int? = null
        private set

    var selectedDevice: AudioDeviceInfo? = null
        private set

    fun devices(): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()
        val inputs = try {
            am.getDevices(AudioManager.GET_DEVICES_INPUTS)
        } catch (_: Throwable) {
            emptyArray()
        }

        for (d in inputs) {
            val type = d.type
            val supported = type == AudioDeviceInfo.TYPE_BUILTIN_MIC ||
                type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
            if (!supported || !d.isSource) continue

            val key = "${d.type}-${d.productName}"
            if (!seen.add(key)) continue

            result += mapOf(
                "id" to d.id,
                "name" to label(d),
                "bluetooth" to (type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO),
                "wired" to (type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                    type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                    type == AudioDeviceInfo.TYPE_USB_HEADSET),
            )
        }

        // Built-in first, then wired, then Bluetooth.
        return result.sortedBy {
            when {
                it["bluetooth"] == true -> 2
                it["wired"] == true -> 1
                else -> 0
            }
        }
    }

    fun select(id: Int?) {
        selectedId = id
        val device = id?.let { wanted ->
            am.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id == wanted }
        }
        selectedDevice = device

        try {
            if (device?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
                am.mode = AudioManager.MODE_IN_COMMUNICATION
                if (Build.VERSION.SDK_INT >= 31) {
                    am.setCommunicationDevice(device)
                } else {
                    @Suppress("DEPRECATION")
                    am.startBluetoothSco()
                    @Suppress("DEPRECATION")
                    am.isBluetoothScoOn = true
                }
            } else {
                if (Build.VERSION.SDK_INT >= 31) {
                    am.clearCommunicationDevice()
                } else {
                    @Suppress("DEPRECATION")
                    am.stopBluetoothSco()
                    @Suppress("DEPRECATION")
                    am.isBluetoothScoOn = false
                }
                am.mode = AudioManager.MODE_NORMAL
            }
        } catch (_: Throwable) {
            // Route switch is best-effort; capture falls back to the default mic.
        }
    }

    fun release() {
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                am.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                am.stopBluetoothSco()
                @Suppress("DEPRECATION")
                am.isBluetoothScoOn = false
            }
            am.mode = AudioManager.MODE_NORMAL
        } catch (_: Throwable) {
        }
    }

    private fun label(d: AudioDeviceInfo): String = when (d.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth mic"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired headset mic"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB mic"
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> d.productName?.toString()
            ?.takeIf { it.isNotBlank() } ?: "Built-in mic"
        else -> d.productName?.toString() ?: "Microphone"
    }
}
