package com.example.password_manager_app

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.roundToInt

class NativeWindowProbeActivity : NativeWindowProbeBaseActivity() {
    override val probeName = "adjustNothing + sticky"
    override val stickyKeyboard = true
}

class NativeWindowProbeResizeActivity : NativeWindowProbeBaseActivity() {
    override val probeName = "adjustResize"
}

class NativeWindowProbePanActivity : NativeWindowProbeBaseActivity() {
    override val probeName = "adjustPan"
}

class NativeWindowProbeNothingActivity : NativeWindowProbeBaseActivity() {
    override val probeName = "adjustNothing"
}

open class NativeWindowProbeBaseActivity : Activity() {
    protected open val probeName = "probe"
    protected open val stickyKeyboard = false

    private lateinit var root: LinearLayout
    private lateinit var search: EditText
    private lateinit var metrics: TextView
    private lateinit var eventTrace: TextView
    private lateinit var content: LinearLayout

    private val keyboardHandler = Handler(Looper.getMainLooper())
    private val events = ArrayDeque<String>()
    private var stickyUntilMs = 0L
    private var stickyTries = 0
    private var stickyScheduled = false
    private var stickyGeneration = 0
    private val categories = listOf("全部分类", "研发", "运维", "云平台", "基础设施", "服务")
    private val tags = listOf("dev", "ops", "prod", "qa", "stage", "cn")
    private val entries = listOf(
        "Alpha Dev" to "研发 / dev, prod",
        "Alpha Ops" to "运维 / ops, cn",
        "Cloud Admin" to "云平台 / prod, stage",
        "Service Token" to "服务 / qa, dev",
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        window.decorView.setOnApplyWindowInsetsListener { view, insets ->
            val ime = insets.getInsets(WindowInsets.Type.ime()).bottom
            record("insets ime=$ime focus=${searchFocused()} window=${hasWindowFocus()}")
            if (stickyKeyboard && ime == 0 && searchFocused() && hasWindowFocus()) {
                startStickyKeyboard("insets0")
            }
            view.post { updateMetrics() }
            insets
        }
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(246, 248, 251))
            setPadding(dp(16), dp(12), dp(16), dp(12))
        }
        setContentView(root)
        record("onCreate $probeName")
        render()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        record("config ${newConfig.screenWidthDp}x${newConfig.screenHeightDp} focus=${searchFocused()} ime=${imeBottom()}")
        if (searchFocused()) {
            startStickyKeyboard("config")
            updateMetrics()
            return
        }
        render()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        record("windowFocus=$hasFocus search=${searchFocused()} ime=${imeBottom()}")
        if (hasFocus && searchFocused()) {
            startStickyKeyboard("windowFocus")
        }
        updateMetrics()
    }

    private fun render() {
        if (!::root.isInitialized) return
        val oldText = if (::search.isInitialized) search.text.toString() else ""
        val hadFocus = ::search.isInitialized && search.hasFocus()
        record("render hadFocus=$hadFocus size=${windowWidthDp()}x${windowHeightDp()} ime=${imeBottom()}")
        root.removeAllViews()

        metrics = TextView(this).apply {
            setTextColor(Color.rgb(71, 85, 105))
            textSize = 12f
            text = metricsText()
        }
        root.addView(metrics, matchWrap())

        eventTrace = TextView(this).apply {
            setTextColor(Color.rgb(100, 116, 139))
            textSize = 11f
            text = eventsText()
            setPadding(0, dp(4), 0, dp(4))
        }
        root.addView(eventTrace, matchWrap())

        val searchRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(10), 0, dp(8))
        }
        search = EditText(this).apply {
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT
            hint = "搜索账号、分类、tag/# 标签"
            textSize = 15f
            setText(oldText)
            setSelection(text.length)
            setOnFocusChangeListener { _, focused ->
                record("searchFocus=$focused ime=${imeBottom()} window=${hasWindowFocus()}")
                if (focused) {
                    startStickyKeyboard("focus")
                } else {
                    stickyGeneration++
                }
                updateMetrics()
            }
        }
        searchRow.addView(search, LinearLayout.LayoutParams(0, dp(48), 1f))
        val help = TextView(this).apply {
            text = "?"
            textSize = 18f
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.rgb(37, 99, 235))
            setOnClickListener { showHelp() }
        }
        searchRow.addView(help, LinearLayout.LayoutParams(dp(44), dp(48)))
        root.addView(searchRow, matchWrap())

        content = LinearLayout(this).apply {
            orientation = if (windowWidthDp() >= 840) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        }
        root.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))

        val listPane = buildListPane()
        if (windowWidthDp() >= 840) {
            content.addView(listPane, LinearLayout.LayoutParams(0, -1, 1f))
            content.addView(buildDetailsPane(), LinearLayout.LayoutParams(0, -1, 1f))
        } else {
            content.addView(listPane, LinearLayout.LayoutParams(-1, -1))
        }

        if (hadFocus) {
            search.requestFocus()
            search.post { requestKeyboard("render") }
        }
    }

    private fun buildListPane(): ScrollView {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, dp(12), 0)
        }
        container.addView(chipRow(categories, maxVisible = if (windowWidthDp() < 600) 3 else categories.size))
        container.addView(chipRow(tags, maxVisible = 3))
        entries.forEach { (title, subtitle) ->
            container.addView(card(title, subtitle))
        }
        return ScrollView(this).apply { addView(container) }
    }

    private fun buildDetailsPane(): View {
        val pane = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            setBackgroundColor(Color.WHITE)
        }
        pane.addView(title("条目详情"))
        pane.addView(body("当前是原生 Android POC，用于验证窗口模式 + 输入法 + 自适应布局。"))
        pane.addView(body("调整窗口到问题尺寸后点击搜索框，观察键盘是否保持。"))
        return pane
    }

    private fun chipRow(items: List<String>, maxVisible: Int): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(6), 0, dp(6))
        }
        items.take(maxVisible).forEach { row.addView(chip(it)) }
        if (items.size > maxVisible) row.addView(chip("...+${items.size - maxVisible}"))
        return row
    }

    private fun chip(text: String): TextView = TextView(this).apply {
        this.text = text
        textSize = 12f
        setTextColor(Color.rgb(30, 41, 59))
        setBackgroundColor(Color.rgb(226, 232, 240))
        setPadding(dp(10), dp(6), dp(10), dp(6))
        val lp = LinearLayout.LayoutParams(-2, -2)
        lp.setMargins(0, 0, dp(8), 0)
        layoutParams = lp
    }

    private fun card(title: String, subtitle: String): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(12))
            setBackgroundColor(Color.WHITE)
        }
        card.addView(title(title))
        card.addView(body(subtitle))
        val lp = LinearLayout.LayoutParams(-1, -2)
        lp.setMargins(0, dp(8), 0, dp(8))
        card.layoutParams = lp
        return card
    }

    private fun title(text: String): TextView = TextView(this).apply {
        this.text = text
        textSize = 16f
        typeface = Typeface.DEFAULT_BOLD
        setTextColor(Color.rgb(15, 23, 42))
    }

    private fun body(text: String): TextView = TextView(this).apply {
        this.text = text
        textSize = 13f
        setTextColor(Color.rgb(71, 85, 105))
        setPadding(0, dp(4), 0, 0)
    }

    private fun showHelp() {
        record("help")
        search.clearFocus()
        android.app.AlertDialog.Builder(this)
            .setTitle("搜索用法")
            .setMessage("普通关键词匹配当前分类；tag:xxx 或 #xxx 做标签搜索；字段示例：title:aws tag:prod ip:10.0。")
            .setPositiveButton("关闭", null)
            .show()
    }

    private fun updateMetrics() {
        if (::metrics.isInitialized) {
            metrics.text = metricsText()
        }
        if (::eventTrace.isInitialized) {
            eventTrace.text = eventsText()
        }
    }

    private fun metricsText(): String {
        val imeBottom = imeBottom()
        val width = windowWidthDp()
        val height = windowHeightDp()
        val mode = if (width >= 840) "two-pane" else if (height < 760) "compact" else "single-pane"
        val focus = if (searchFocused()) "focused" else "not-focused"
        return "$probeName | ${width}dp x ${height}dp | ime=$imeBottom px | $mode | $focus | window=${hasWindowFocus()}"
    }

    private fun startStickyKeyboard(reason: String) {
        if (!stickyKeyboard || !searchFocused()) return
        stickyUntilMs = SystemClock.uptimeMillis() + 1400
        stickyTries = 0
        scheduleStickyKeyboard(reason, 30)
    }

    private fun scheduleStickyKeyboard(reason: String, delayMs: Long) {
        if (stickyScheduled || !stickyKeyboard || !searchFocused()) return
        stickyScheduled = true
        val generation = stickyGeneration
        keyboardHandler.postDelayed({
            stickyScheduled = false
            if (generation != stickyGeneration ||
                !stickyKeyboard ||
                !searchFocused() ||
                !hasWindowFocus()
            ) {
                return@postDelayed
            }
            val now = SystemClock.uptimeMillis()
            if (now > stickyUntilMs || stickyTries >= 6) {
                return@postDelayed
            }
            if (imeBottom() == 0 || stickyTries == 0) {
                stickyTries++
                requestKeyboard("$reason#$stickyTries")
            }
            scheduleStickyKeyboard(reason, 180)
        }, delayMs)
    }

    private fun requestKeyboard(reason: String) {
        if (!::search.isInitialized) return
        search.requestFocus()
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val shown = imm.showSoftInput(search, InputMethodManager.SHOW_IMPLICIT)
        record("showSoftInput $reason result=$shown ime=${imeBottom()}")
    }

    private fun record(message: String) {
        val entry = "${SystemClock.uptimeMillis() % 100000}: $message"
        events.addFirst(entry)
        while (events.size > 6) {
            events.removeLast()
        }
        Log.d("NativeWindowProbe", entry)
    }

    private fun eventsText(): String = events.joinToString(separator = "\n")

    private fun imeBottom(): Int {
        if (!::root.isInitialized) return 0
        return root.rootWindowInsets
            ?.getInsets(WindowInsets.Type.ime())
            ?.bottom ?: 0
    }

    private fun searchFocused(): Boolean = ::search.isInitialized && search.hasFocus()
    private fun windowWidthDp(): Int = (resources.configuration.screenWidthDp)
    private fun windowHeightDp(): Int = (resources.configuration.screenHeightDp)
    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()
    private fun matchWrap() = LinearLayout.LayoutParams(-1, -2)
}
