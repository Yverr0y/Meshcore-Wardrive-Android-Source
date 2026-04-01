package mintylinux.meshcore.wardrive

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val TAG = "MeshcoreFeedback"
    private val CHANNEL = "mintylinux.meshcore.wardrive/feedback"
    private var toneGenerator: ToneGenerator? = null

    private fun getVibrator(): Vibrator {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val mgr = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            mgr.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        toneGenerator = try {
            ToneGenerator(AudioManager.STREAM_MUSIC, 100)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create ToneGenerator", e)
            null
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playTone" -> {
                        val tone = call.argument<Int>("tone") ?: ToneGenerator.TONE_PROP_BEEP
                        val durationMs = call.argument<Int>("durationMs") ?: 150
                        toneGenerator?.startTone(tone, durationMs)
                        result.success(null)
                    }
                    "vibrate" -> {
                        try {
                            val durationMs = (call.argument<Int>("durationMs") ?: 100).toLong()
                            val amplitude = call.argument<Int>("amplitude") ?: VibrationEffect.DEFAULT_AMPLITUDE
                            val vibrator = getVibrator()
                            Log.d(TAG, "Vibrator hasVibrator=${vibrator.hasVibrator()}, SDK=${Build.VERSION.SDK_INT}")
                            val effect = VibrationEffect.createOneShot(durationMs, amplitude)
                            if (Build.VERSION.SDK_INT >= 33) {
                                // Use ALARM usage so vibration isn't blocked by "touch vibration" setting
                                val attrs = VibrationAttributes.Builder()
                                    .setUsage(VibrationAttributes.USAGE_ALARM)
                                    .build()
                                vibrator.vibrate(effect, attrs)
                                Log.d(TAG, "Vibrate (ALARM attrs): ${durationMs}ms, amp=$amplitude")
                            } else {
                                vibrator.vibrate(effect)
                                Log.d(TAG, "Vibrate (default): ${durationMs}ms, amp=$amplitude")
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e(TAG, "Vibrate failed", e)
                            result.error("VIBRATE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        toneGenerator?.release()
        toneGenerator = null
        super.onDestroy()
    }
}
