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
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

class LyricOverlayService : Service() {
    companion object {
        const val ACTION_START = "cn.yinsu.x_music.OVERLAY_START"
        const val ACTION_STOP = "cn.yinsu.x_music.OVERLAY_STOP"
        const val ACTION_UPDATE = "cn.yinsu.x_music.OVERLAY_UPDATE"
        const val ACTION_PROGRESS = "cn.yinsu.x_music.OVERLAY_PROGRESS"
        const val EXTRA_LINES = "lines"
        const val EXTRA_CURRENT = "current"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_DURATION = "duration"
        @Volatile var accessibilityForeground: String? = null
        private const val CHANNEL_ID = "xmusic_lyric_overlay"
        private const val VISIBLE_LINES = 5
    }

    private var wm: WindowManager? = null
    private var root: LinearLayout? = null
    private var added = false
    private val lyricViews = ArrayList<TextView>()
    private var progressBar: ProgressBar? = null
    private var _hasLyric = false
    private var _lines: List<String> = emptyList()
    private var _current = -1
    private var _progressMs = 0
    private var _durationMs = 0
    private val handler = Handler(Looper.getMainLooper())
    private var loopTask: Runnable? = null
    private var lp: WindowManager.LayoutParams? = null
    private var lastX = 0f
    private var lastY = 0f

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundCompat()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE -> {
                val lines = intent.getStringArrayListExtra(EXTRA_LINES) ?: emptyList()
                val current = intent.getIntExtra(EXTRA_CURRENT, -1)
                val progress = intent.getIntExtra(EXTRA_PROGRESS, 0)
                val duration = intent.getIntExtra(EXTRA_DURATION, 0)
                _hasLyric = lines.isNotEmpty() && current >= 0
                _lines = lines
                _current = current
                _progressMs = progress
                _durationMs = duration
                renderLyrics()
                updateProgressBar()
            }
            ACTION_PROGRESS -> {
                _progressMs = intent.getIntExtra(EXTRA_PROGRESS, 0)
                _durationMs = intent.getIntExtra(EXTRA_DURATION, 0)
                updateProgressBar()
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

    /**
     * 显示条件（用户明确要求）：只在「迪友桌面（设备默认启动器/桌面）」在前台时显示。
     * - 迪友小窗、其它任意 app、其它全屏界面：一律不显示。
     * - 不再用「车机大屏常显」兜底（此前导致全场景都浮，已被用户否决）。
     */
    private fun updateVisibility() {
        val launcher = launcherPackage()
        val top = topPackage()
        val show = _hasLyric && launcher != null && top != null && top == launcher
        if (show && !added) addView()
        else if (!show && added) removeView()
    }

    private fun buildView(): LinearLayout {
        val d = resources.displayMetrics.density
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding((16 * d).toInt(), (10 * d).toInt(), (16 * d).toInt(), (10 * d).toInt())

        val bg = GradientDrawable()
        bg.cornerRadius = (14 * d).toInt()
        bg.setColor(0xB8000000.toInt()) // 深色玻璃半透明底
        root.background = bg

        // 歌词容器：固定 5 行，中间行高亮
        val box = LinearLayout(this)
        box.orientation = LinearLayout.VERTICAL
        box.gravity = Gravity.CENTER
        lyricViews.clear()
        for (i in 0 until VISIBLE_LINES) {
            val tv = TextView(this)
            tv.setTextColor(0x99FFFFFF.toInt())
            tv.setTextSize(15f)
            tv.gravity = Gravity.CENTER
            tv.setSingleLine(true)
            tv.ellipsize = android.text.TextUtils.TruncateAt.END
            tv.setPadding(0, (3 * d).toInt(), 0, (3 * d).toInt())
            box.addView(tv, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ))
            lyricViews.add(tv)
        }
        root.addView(box)

        // 进度条
        val pb = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal)
        pb.max = 1000
        pb.progress = 0
        val pbp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            (4 * d).toInt()
        )
        pbp.topMargin = (8 * d).toInt()
        root.addView(pb, pbp)
        progressBar = pb

        // 时间显示：当前 / 总时长
        val time = TextView(this)
        time.setTextColor(0xBBFFFFFF.toInt())
        time.setTextSize(12f)
        time.gravity = Gravity.END
        root.addView(time, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ))
        timeView = time
        return root
    }

    private var timeView: TextView? = null

    private fun renderLyrics() {
        if (root == null) return
        val center = _current
        for (i in 0 until VISIBLE_LINES) {
            val tv = lyricViews.getOrNull(i) ?: continue
            val lineIdx = center - 2 + i
            val text = if (lineIdx >= 0 && lineIdx < _lines.size) _lines[lineIdx] else ""
            tv.text = text
            val isCenter = (i == 2) && lineIdx >= 0 && lineIdx < _lines.size
            if (isCenter) {
                tv.setTextColor(0xFFFFFFFF.toInt())
                tv.setTextSize(17f)
                tv.setTypeface(null, Typeface.BOLD)
            } else {
                tv.setTextColor(0x88FFFFFF.toInt())
                tv.setTextSize(14f)
                tv.setTypeface(null, Typeface.NORMAL)
            }
        }
        updateProgressBar()
        updateTime()
    }

    private fun updateProgressBar() {
        val pb = progressBar ?: return
        if (_durationMs > 0) {
            pb.progress = ((_progressMs.toFloat() / _durationMs) * 1000).toInt().coerceIn(0, 1000)
        } else {
            pb.progress = 0
        }
    }

    private fun updateTime() {
        val tv = timeView ?: return
        val cur = formatMs(_progressMs)
        val dur = formatMs(_durationMs)
        tv.text = "$cur / $dur"
    }

    private fun formatMs(ms: Int): String {
        val t = ms / 1000
        val m = t / 60
        val s = t % 60
        return "%02d:%02d".format(m, s)
    }

    private fun addView() {
        if (added) return
        val d = resources.displayMetrics.density
        lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        )
        lp!!.gravity = Gravity.TOP or Gravity.LEFT
        lp!!.x = 0
        lp!!.y = (90 * d).toInt()
        val v = buildView()
        root = v
        // 拖动
        v.setOnTouchListener { _, ev ->
            when (ev.action) {
                MotionEvent.ACTION_DOWN -> {
                    lastX = ev.rawX
                    lastY = ev.rawY
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - lastX
                    val dy = ev.rawY - lastY
                    val params = lp ?: return@setOnTouchListener true
                    params.x += dx.toInt()
                    params.y += dy.toInt()
                    try { wm?.updateViewLayout(v, params) } catch (_: Exception) {}
                    lastX = ev.rawX
                    lastY = ev.rawY
                    true
                }
                else -> false
            }
        }
        renderLyrics()
        try {
            wm?.addView(v, lp!!)
            added = true
        } catch (_: Exception) {
            added = false
        }
    }

    private fun removeView() {
        root?.let { v ->
            try { wm?.removeView(v) } catch (_: Exception) {}
        }
        root = null
        lyricViews.clear()
        progressBar = null
        timeView = null
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
