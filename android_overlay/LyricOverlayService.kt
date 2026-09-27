package __PKG__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView

class LyricOverlayService : Service() {
    companion object {
        const val ACTION_START = "cn.yinsu.x_music.OVERLAY_START"
        const val ACTION_STOP = "cn.yinsu.x_music.OVERLAY_STOP"
        const val ACTION_UPDATE = "cn.yinsu.x_music.OVERLAY_UPDATE"
        const val EXTRA_LYRIC = "lyric"
        @Volatile var accessibilityForeground: String? = null
        private const val CHANNEL_ID = "xmusic_lyric_overlay"
    }

    private var wm: WindowManager? = null
    private var view: TextView? = null
    private var added = false
    private var _lyric: String = ""
    private val handler = Handler(Looper.getMainLooper())
    private var loopTask: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundCompat()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE -> {
                val text = intent.getStringExtra(EXTRA_LYRIC) ?: ""
                if (text.isNotEmpty()) {
                    _lyric = text
                    view?.text = text
                }
            }
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        startLoop()
        return START_STICKY
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "歌词悬浮窗", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val pi = PendingIntent.getActivity(
            this, 0, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        val notif = b.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("音素音乐")
            .setContentText("歌词悬浮窗运行中")
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(1, notif)
        }
    }

    private fun startLoop() {
        loopTask?.let { handler.removeCallbacks(it) }
        loopTask = Runnable {
            updateVisibility()
            handler.postDelayed(loopTask!!, 1000)
        }
        handler.post(loopTask!!)
    }

    private fun launcherPackage(): String? {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val ri = packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        return ri?.activityInfo?.packageName
    }

    private fun topPackage(): String? {
        // 无障碍实时前台优先；否则 UsageStats 兜底
        accessibilityForeground?.let { if (it.isNotEmpty()) return it }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
                val end = System.currentTimeMillis()
                val events = usm.queryEvents(end - 3000, end)
                var top: String? = null
                while (events.hasNextEvent()) {
                    val e = UsageEvents.Event()
                    events.getNextEvent(e)
                    if (e.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) top = e.packageName
                }
                return top
            } catch (_: Exception) {}
        }
        return null
    }

    private fun updateVisibility() {
        val launcher = launcherPackage()
        val top = topPackage()
        val show = launcher != null && top == launcher && _lyric.isNotEmpty()
        if (show && !added) addView()
        else if (!show && added) removeView()
    }

    private fun addView() {
        if (added) return
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        lp.y = (resources.displayMetrics.density * 40).toInt()
        val tv = TextView(this)
        tv.text = _lyric
        tv.setTextColor(0xFFFFFFFF.toInt())
        tv.setTextSize(16f)
        val d = resources.displayMetrics.density
        tv.setPadding((18 * d).toInt(), (8 * d).toInt(), (18 * d).toInt(), (8 * d).toInt())
        tv.setBackgroundColor(0x99000000.toInt())
        tv.setGravity(Gravity.CENTER)
        view = tv
        try {
            wm?.addView(tv, lp)
            added = true
        } catch (_: Exception) {
            added = false
        }
    }

    private fun removeView() {
        view?.let { v ->
            try { wm?.removeView(v) } catch (_: Exception) {}
        }
        view = null
        added = false
    }

    override fun onDestroy() {
        loopTask?.let { handler.removeCallbacks(it) }
        removeView()
        wm = null
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (added) {
            removeView()
            addView()
        }
    }
}
