/*
 * Copyright (C) 2018-2020 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Rewritten in Kotlin by Pavel Dubrova <pashadubrova@gmail.com>
 */

package com.sony.qcrilam

import android.app.Service
import android.content.Intent
import android.media.AudioManager
import android.os.IBinder
import android.os.RemoteException
import android.telephony.SubscriptionManager
import android.util.Log
import vendor.qti.hardware.radio.am.V1_0.IQcRilAudio
import vendor.qti.hardware.radio.am.V1_0.IQcRilAudioCallback

private const val TAG = "QcRilAm-Service"

class QcRilAmService : Service() {
    private fun addCallbackForSimSlot(simSlotNo: Int, audioManager: AudioManager) {
        try {
            val qcRilAudio = IQcRilAudio.getService("slot$simSlotNo", true /*retry*/)
            if (qcRilAudio == null) {
                Log.e(TAG, "Could not get service instance for slot$simSlotNo, failing")
            } else {
                qcRilAudio.setCallback(object : IQcRilAudioCallback.Stub() {
                    override fun getParameters(keys: String?): String {
                        return audioManager.getParameters(keys)
                    }

                    override fun setParameters(keyValuePairs: String?): Int {
                        // AudioManager.setParameters does not check nor return
                        // the value coming from AudioSystem.setParameters.
                        // Assume there was no error:
                        audioManager.setParameters(keyValuePairs)
                        return 0
                    }
                })
            }
        } catch (exception: RemoteException) {
            Log.e(TAG, "RemoteException while trying to add callback for slot$simSlotNo")
        }
    }

    override fun onBind(intent: Intent?) = null

    override fun onCreate() {
        val simCount = getSystemService(SubscriptionManager::class.java).getActiveSubscriptionInfoCountMax()
        Log.i(TAG, "Device has $simCount sim slots")
        val audioManager = getSystemService(AudioManager::class.java)
        if (audioManager == null) {
            throw RuntimeException("Can't get audiomanager!")
        }
        for (simSlotNo in 1..simCount) {
            addCallbackForSimSlot(simSlotNo, audioManager)
        }
    }
}
