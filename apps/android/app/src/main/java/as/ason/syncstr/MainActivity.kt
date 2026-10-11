package `as`.ason.syncstr

import android.app.Activity
import android.app.AlertDialog
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : Activity() {
    companion object { private val worker = Executors.newSingleThreadExecutor() }
    private lateinit var key: ByteArray
    private lateinit var content: LinearLayout
    private lateinit var status: TextView
    private lateinit var conflictsView: TextView
    private lateinit var discovery: LanDiscovery
    private var catalog = JSONArray()
    private var conflicts = JSONArray()
    private val addresses = mutableMapOf<String, String>()
    private var player: MediaPlayer? = null
    private var prepared = false
    private var focus: AudioFocusRequest? = null
    private var busy = false
    private val controls = mutableListOf<Button>()

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(20), dp(20), dp(20)) }
        content.setOnApplyWindowInsetsListener { view, insets ->
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                val system = insets.getInsets(android.view.WindowInsets.Type.systemBars())
                view.setPadding(dp(20) + system.left, dp(20) + system.top, dp(20) + system.right, dp(20) + system.bottom)
            } else {
                @Suppress("DEPRECATION")
                view.setPadding(dp(20) + insets.systemWindowInsetLeft, dp(20) + insets.systemWindowInsetTop,
                    dp(20) + insets.systemWindowInsetRight, dp(20) + insets.systemWindowInsetBottom)
            }
            insets
        }
        setContentView(ScrollView(this).apply { addView(content) })
        status = TextView(this).apply { text = "ライブラリを読み込んでいます"; setPadding(0, dp(8), 0, dp(16)) }
        content.addView(status)
        conflictsView = TextView(this)
        content.addView(conflictsView)
        try { key = DeviceKey(this).load() } catch (error: Exception) { status.text = error.message; return }
        discovery = LanDiscovery(this) { id, socket ->
            if (socket == null) addresses.remove(id) else addresses[id] = socket
        }
        discovery.start()
        button("接続先を登録") { invitationDialog() }
        button("ライブラリを更新") { refresh() }
        button("再生 / 一時停止") {
            if (!prepared) return@button
            val active = player
            if (active?.isPlaying == true) active.pause()
            else if (active != null && requestAudioFocus()) active.start()
        }
        task { loadCatalog(); onUi {
            status.text = if (catalog.length() == 0) "接続先を登録して音楽を追加してください。" else ""
            render()
        } }
    }

    private fun call(operation: String, args: JSONObject = JSONObject()): String =
        Native.run(filesDir.resolve("library").path, key, operation, args.toString())

    private fun loadCatalog() {
        val library = JSONObject(call("catalog"))
        catalog = library.getJSONArray("entries")
        conflicts = library.getJSONArray("conflicts")
    }

    private fun invitationDialog() {
        val input = EditText(this).apply { hint = "接続先の招待情報を貼り付け"; minLines = 4 }
        AlertDialog.Builder(this).setTitle("接続先を登録").setView(input).setNegativeButton("キャンセル", null)
            .setPositiveButton("登録") { _, _ ->
                val invitation = input.text.toString()
                try {
                    require(invitation.length <= 16 * 1024) { "招待情報が長すぎます。" }
                    val host = JSONObject(invitation).getString("host")
                    require(host.matches(Regex("[0-9a-f]{64}"))) { "接続先のIDが正しくありません。" }
                    AlertDialog.Builder(this).setTitle("接続先のIDを確認")
                        .setMessage(host).setNegativeButton("キャンセル", null)
                        .setPositiveButton("確認して登録") { _, _ -> task {
                            val socket = onMainAddress(host)
                            call("enroll", JSONObject().put("invitation", invitation).put("socket", socket))
                            call("refresh", JSONObject().put("host", host).put("socket", socket))
                            loadCatalog()
                            onUi { status.text = "登録しました"; render() }
                        } }.show()
                } catch (error: Exception) { status.text = error.message }
            }.show()
    }

    private fun onMainAddress(host: String): String {
        val result = java.util.concurrent.CompletableFuture<String>()
        runOnUiThread {
            val socket = addresses[host]
            if (socket == null) result.completeExceptionally(IllegalStateException("接続先が見つかりません。同じWi-Fiに接続してから再試行してください。"))
            else result.complete(socket)
        }
        return result.get()
    }

    private fun refresh() { task {
        val sources = availableHosts()
        var success = false
        var failure: Exception? = null
        for (index in 0 until sources.length()) {
            try { call("refresh", sources.getJSONObject(index)); success = true }
            catch (error: Exception) { failure = error }
        }
        if (!success) throw requireNotNull(failure)
        loadCatalog()
        onUi { status.text = "ライブラリを更新しました"; render() }
    } }

    private fun availableHosts(): JSONArray {
        val hosts = JSONArray(call("hosts"))
        check(hosts.length() > 0) { "接続先を登録してください。" }
        val result = java.util.concurrent.CompletableFuture<JSONArray>()
        runOnUiThread {
            val available = JSONArray()
            for (index in 0 until hosts.length()) {
                val host = hosts.getString(index)
                addresses[host]?.let { available.put(JSONObject().put("host", host).put("socket", it)) }
            }
            if (available.length() == 0) result.completeExceptionally(IllegalStateException("接続先が見つかりません。同じWi-Fiに接続してください。"))
            else result.complete(available)
        }
        return result.get()
    }

    private fun render() {
        while (content.childCount > 5) content.removeViewAt(5)
        conflictsView.text = if (conflicts.length() == 0) "" else "競合している音源が${conflicts.length()}件あります。保存先のSyncstrで優先する情報を選んでください。\n" +
            (0 until minOf(conflicts.length(), 20)).joinToString("\n") { conflicts.getString(it) }
        controls.retainAll { it.parent != null }
        for (index in 0 until catalog.length()) {
            val entry = catalog.getJSONObject(index)
            val track = entry.getJSONObject("track")
            content.addView(TextView(this).apply { text = "${track.getString("title")}\n${track.optString("artist").ifBlank { "アーティスト不明" }}"; setPadding(0, dp(20), 0, dp(4)) })
            button("再生 / 端末に保存") {
                task {
                    val objectId = entry.getString("sha256")
                    val args = JSONObject().put("object", objectId)
                    val local = org.json.JSONTokener(call("local-file", args)).nextValue()
                    val path = if (local is String) local else {
                        val saved = call("download", args.put("addresses", availableHosts()))
                        org.json.JSONTokener(saved).nextValue() as String
                    }
                    onUi { play(path, track.getString("title")) }
                }
            }
        }
    }

    private fun play(path: String, title: String) {
        player?.release()
        prepared = false
        player = MediaPlayer().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            setDataSource(path)
            setOnPreparedListener { prepared = true; if (hasWindowFocus() && requestAudioFocus()) { it.start(); status.text = title } }
            setOnErrorListener { _, _, _ -> prepared = false; status.text = "音源を再生できませんでした"; true }
            prepareAsync()
        }
    }

    private fun requestAudioFocus(): Boolean {
        val audio = getSystemService(AudioManager::class.java)
        if (focus == null) focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
            .setOnAudioFocusChangeListener { change ->
                if (change != AudioManager.AUDIOFOCUS_GAIN && prepared && player?.isPlaying == true) player?.pause()
            }.build()
        return audio.requestAudioFocus(requireNotNull(focus)) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun button(label: String, action: () -> Unit) {
        val view = Button(this).apply { text = label; isEnabled = !busy; setOnClickListener { action() } }
        controls.add(view)
        content.addView(view)
    }

    private fun task(action: () -> Unit) {
        if (busy) return
        busy = true
        controls.forEach { it.isEnabled = false }
        status.text = "処理しています"
        worker.execute {
            try { action() } catch (error: Exception) { onUi { status.text = error.cause?.message ?: error.message } }
            finally { onUi { busy = false; controls.forEach { it.isEnabled = true } } }
        }
    }

    private fun onUi(action: () -> Unit) { runOnUiThread { if (!isDestroyed) action() } }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    override fun onDestroy() {
        if (::discovery.isInitialized) discovery.stop()
        player?.release()
        focus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }
        super.onDestroy()
    }

    override fun onStop() {
        if (prepared && player?.isPlaying == true) player?.pause()
        super.onStop()
    }
}
