package __PKG__

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lyric_overlay").setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    val i = Intent(this, LyricOverlayService::class.java)
                    i.action = LyricOverlayService.ACTION_START
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
                    result.success(true)
                }
                "disable" -> {
                    val i = Intent(this, LyricOverlayService::class.java)
                    i.action = LyricOverlayService.ACTION_STOP
                    try { startService(i) } catch (_: Exception) {}
                    result.success(true)
                }
                "updateLyric" -> {
                    val lines = call.argument<List<String>>("lines") ?: emptyList()
                    val current = call.argument<Int>("current") ?: -1
                    val progress = call.argument<Int>("progressMs") ?: 0
                    val duration = call.argument<Int>("durationMs") ?: 0
                    val i = Intent(this, LyricOverlayService::class.java)
                    i.action = LyricOverlayService.ACTION_UPDATE
                    i.putStringArrayListExtra(LyricOverlayService.EXTRA_LINES, ArrayList(lines))
                    i.putExtra(LyricOverlayService.EXTRA_CURRENT, current)
                    i.putExtra(LyricOverlayService.EXTRA_PROGRESS, progress)
                    i.putExtra(LyricOverlayService.EXTRA_DURATION, duration)
                    try { startService(i) } catch (_: Exception) {}
                    result.success(true)
                }
                "updateProgress" -> {
                    val progress = call.argument<Int>("progressMs") ?: 0
                    val duration = call.argument<Int>("durationMs") ?: 0
                    val i = Intent(this, LyricOverlayService::class.java)
                    i.action = LyricOverlayService.ACTION_PROGRESS
                    i.putExtra(LyricOverlayService.EXTRA_PROGRESS, progress)
                    i.putExtra(LyricOverlayService.EXTRA_DURATION, duration)
                    try { startService(i) } catch (_: Exception) {}
                    result.success(true)
                }
                "checkPermissions" -> result.success(mapOf(
                    "overlay" to Settings.canDrawOverlays(this),
                    "usageStats" to isUsageGranted(),
                    "accessibility" to isAccessibilityOn()
                ))
                "requestOverlay" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
                    result.success(true)
                }
                "requestUsageStats" -> {
                    startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                    result.success(true)
                }
                "requestAccessibility" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isUsageGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        return try {
            val appOps = getSystemService(APP_OPS_SERVICE) as android.app.AppOpsManager
            appOps.checkOpNoThrow(
                android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(), packageName
            ) == android.app.AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) { false }
    }

    private fun isAccessibilityOn(): Boolean {
        val expected = "$packageName/.LyricAccessibilityService"
        val enabled = Settings.Secure.getString(
            contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabled.split(':').any { it.equals(expected, true) }
    }
}
