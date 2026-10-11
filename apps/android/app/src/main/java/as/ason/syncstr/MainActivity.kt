package `as`.ason.syncstr

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors

class MainActivity : Activity() {
    companion object {
        private val worker = Executors.newSingleThreadExecutor()
        private const val GRAPHITE = 0xff232426.toInt()
        private const val CARBON = 0xff121214.toInt()
        private const val IRON = 0xff45464d.toInt()
        private const val WHITE = 0xffffffff.toInt()
        private const val FOG = 0xffa6a8ad.toInt()
        private const val BLUE = 0xff1253ff.toInt()
    }

    private enum class Screen { LIBRARY, SAVED, PLAYER, CONNECTIONS }
    private enum class SaveState { REMOTE, DOWNLOADING, SAVED, FAILED }

    private lateinit var key: ByteArray
    private lateinit var root: LinearLayout
    private lateinit var body: FrameLayout
    private lateinit var status: TextView
    private lateinit var miniPlayer: LinearLayout
    private lateinit var discovery: LanDiscovery
    private val handler = Handler(Looper.getMainLooper())
    private val controls = mutableListOf<View>()
    private val addresses = mutableMapOf<String, String>()
    private val saveStates = mutableMapOf<String, SaveState>()
    private var catalog = JSONArray()
    private var conflicts = JSONArray()
    private var screen = Screen.LIBRARY
    private var player: MediaPlayer? = null
    private var playingEntry: JSONObject? = null
    private var prepared = false
    private var focus: AudioFocusRequest? = null
    private var busy = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.statusBarColor = GRAPHITE
        window.navigationBarColor = CARBON
        buildChrome()
        try { key = DeviceKey(this).load() } catch (error: Exception) {
            showStatus(error.message ?: getString(R.string.identity_error), true)
            return
        }
        discovery = LanDiscovery(this) { id, socket -> if (socket == null) addresses.remove(id) else addresses[id] = socket }
        discovery.start()
        task { loadCatalog(); onUi { if (catalog.length() == 0) showStatus(getString(R.string.empty_library_hint)); render() } }
    }

    private fun buildChrome() {
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(GRAPHITE)
            setOnApplyWindowInsetsListener { view, insets ->
                if (android.os.Build.VERSION.SDK_INT >= 30) {
                    val bars = insets.getInsets(WindowInsets.Type.systemBars())
                    view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                } else {
                    @Suppress("DEPRECATION")
                    view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                        insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                }
                insets
            }
        }
        root.addView(LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(8), dp(8), dp(8))
            addView(label(getString(R.string.app_name), 24f, WHITE, true), LinearLayout.LayoutParams(0, dp(48), 1f))
            addView(action(getString(R.string.refresh)) { refreshLibrary() })
            addView(action(getString(R.string.connections)) { navigate(Screen.CONNECTIONS) })
        })
        status = label("", 14f, WHITE).apply {
            visibility = View.GONE
            setBackgroundColor(CARBON)
            setPadding(dp(16), dp(10), dp(16), dp(10))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        root.addView(status)
        body = FrameLayout(this)
        root.addView(body, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        miniPlayer = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(8), dp(8), dp(8))
            setBackgroundColor(CARBON)
            visibility = View.GONE
            isClickable = true
            setOnClickListener { navigate(Screen.PLAYER) }
        }
        root.addView(miniPlayer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)))
        root.addView(LinearLayout(this).apply {
            setBackgroundColor(CARBON)
            addView(nav(getString(R.string.library), Screen.LIBRARY), LinearLayout.LayoutParams(0, dp(56), 1f))
            addView(nav(getString(R.string.saved), Screen.SAVED), LinearLayout.LayoutParams(0, dp(56), 1f))
            addView(nav(getString(R.string.now_playing), Screen.PLAYER), LinearLayout.LayoutParams(0, dp(56), 1f))
        })
        setContentView(root)
    }

    private fun nav(text: String, target: Screen) = Button(this).apply {
        this.text = text
        setTextColor(WHITE)
        setBackgroundColor(Color.TRANSPARENT)
        contentDescription = text
        setOnClickListener { navigate(target) }
    }

    private fun navigate(target: Screen) { screen = target; render() }
    private fun call(operation: String, args: JSONObject = JSONObject()) = Native.run(filesDir.resolve("library").path, key, operation, args.toString())

    private fun loadCatalog() {
        val library = JSONObject(call("catalog"))
        catalog = library.getJSONArray("entries")
        conflicts = library.getJSONArray("conflicts")
        for (index in 0 until catalog.length()) {
            val id = catalog.getJSONObject(index).getString("sha256")
            val local = org.json.JSONTokener(call("local-file", JSONObject().put("object", id))).nextValue()
            saveStates[id] = if (local is String) SaveState.SAVED else SaveState.REMOTE
        }
    }

    private fun refreshLibrary() = task {
        val sources = availableHosts()
        var success = false
        var failure: Exception? = null
        for (index in 0 until sources.length()) try {
            call("refresh", sources.getJSONObject(index)); success = true
        } catch (error: Exception) { failure = error }
        if (!success) throw requireNotNull(failure)
        loadCatalog()
        onUi { showStatus(getString(R.string.library_updated)); render() }
    }

    private fun render() {
        body.removeAllViews()
        controls.clear()
        when (screen) {
            Screen.LIBRARY -> renderLibrary(false)
            Screen.SAVED -> renderLibrary(true)
            Screen.PLAYER -> renderPlayer()
            Screen.CONNECTIONS -> renderConnections()
        }
        renderMiniPlayer()
        controls.forEach { it.isEnabled = !busy }
    }

    private fun renderLibrary(savedOnly: Boolean) {
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(12), dp(20), dp(32)) }
        body.addView(ScrollView(this).apply { addView(list) })
        if (!savedOnly && conflicts.length() > 0) list.addView(conflictCard())
        val entries = (0 until catalog.length()).map { catalog.getJSONObject(it) }
            .filter { !savedOnly || saveStates[it.getString("sha256")] == SaveState.SAVED }
        if (entries.isEmpty()) {
            list.addView(emptyState(getString(if (savedOnly) R.string.no_saved_music else R.string.no_music)))
            return
        }
        val albums = entries.groupBy { it.getJSONObject("track").optString("album").ifBlank { getString(R.string.unknown_album) } }
            .toSortedMap(String.CASE_INSENSITIVE_ORDER)
        for ((album, tracks) in albums) {
            val artist = tracks.firstNotNullOfOrNull { it.getJSONObject("track").optString("artist").takeIf(String::isNotBlank) }
                ?: getString(R.string.unknown_artist)
            list.addView(LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(24), 0, dp(8))
                addView(label(album, 21f, WHITE, true))
                addView(label(getString(R.string.album_subtitle, artist, resources.getQuantityString(R.plurals.track_count, tracks.size, tracks.size)), 14f, FOG))
            })
            tracks.sortedBy { it.getJSONObject("track").optInt("track", Int.MAX_VALUE) }.forEach { list.addView(trackRow(it)) }
        }
    }

    private fun trackRow(entry: JSONObject) = LinearLayout(this).apply {
        val track = entry.getJSONObject("track")
        val id = entry.getString("sha256")
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(12), dp(8), dp(4), dp(8))
        setBackgroundColor(CARBON)
        addView(label(track.optInt("track", 0).takeIf { it > 0 }?.toString() ?: "–", 14f, FOG), LinearLayout.LayoutParams(dp(32), -2))
        addView(LinearLayout(this@MainActivity).apply {
            orientation = LinearLayout.VERTICAL
            addView(label(track.getString("title"), 16f, WHITE).apply { maxLines = 2 })
            addView(label(saveLabel(saveStates[id] ?: SaveState.REMOTE), 13f, if (saveStates[id] == SaveState.FAILED) 0xffff8a80.toInt() else FOG))
        }, LinearLayout.LayoutParams(0, -2, 1f))
        when (saveStates[id] ?: SaveState.REMOTE) {
            SaveState.SAVED -> addView(primary(getString(R.string.play)) { playSaved(entry) })
            SaveState.DOWNLOADING -> addView(ProgressBar(this@MainActivity).apply { contentDescription = getString(R.string.downloading) }, LinearLayout.LayoutParams(dp(48), dp(48)))
            SaveState.REMOTE, SaveState.FAILED -> addView(primary(getString(if (saveStates[id] == SaveState.FAILED) R.string.retry else R.string.save)) { saveTrack(entry) })
        }
    }

    private fun saveLabel(state: SaveState) = getString(when (state) {
        SaveState.REMOTE -> R.string.available_on_library
        SaveState.DOWNLOADING -> R.string.downloading
        SaveState.SAVED -> R.string.saved_on_device
        SaveState.FAILED -> R.string.download_failed
    })

    private fun saveTrack(entry: JSONObject) {
        val id = entry.getString("sha256")
        saveStates[id] = SaveState.DOWNLOADING
        render()
        task {
            try {
                call("download", JSONObject().put("object", id).put("addresses", availableHosts()))
                saveStates[id] = SaveState.SAVED
                onUi { showStatus(getString(R.string.saved_track, entry.getJSONObject("track").getString("title"))); render() }
            } catch (error: Exception) { saveStates[id] = SaveState.FAILED; throw error }
        }
    }

    private fun playSaved(entry: JSONObject) = task {
        val value = org.json.JSONTokener(call("local-file", JSONObject().put("object", entry.getString("sha256")))).nextValue()
        val path = value as? String ?: error(getString(R.string.saved_file_missing))
        onUi { startPlayback(path, entry) }
    }

    private fun startPlayback(path: String, entry: JSONObject) {
        player?.release(); prepared = false; playingEntry = entry; renderMiniPlayer()
        player = MediaPlayer().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            setDataSource(path)
            setOnPreparedListener { prepared = true; if (hasWindowFocus() && requestAudioFocus()) it.start(); render(); scheduleProgress() }
            setOnCompletionListener { render() }
            setOnErrorListener { _, _, _ -> prepared = false; showStatus(getString(R.string.playback_failed), true); true }
            prepareAsync()
        }
    }

    private fun togglePlayback() {
        if (!prepared) return
        val active = player ?: return
        if (active.isPlaying) active.pause() else if (requestAudioFocus()) active.start()
        render(); scheduleProgress()
    }

    private fun renderMiniPlayer() {
        miniPlayer.removeAllViews()
        val entry = playingEntry ?: run { miniPlayer.visibility = View.GONE; return }
        miniPlayer.visibility = View.VISIBLE
        val track = entry.getJSONObject("track")
        miniPlayer.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label(track.getString("title"), 15f, WHITE, true).apply { maxLines = 1 })
            addView(label(track.optString("artist").ifBlank { getString(R.string.unknown_artist) }, 13f, FOG).apply { maxLines = 1 })
        }, LinearLayout.LayoutParams(0, -2, 1f))
        miniPlayer.addView(primary(getString(if (player?.isPlaying == true) R.string.pause else R.string.play)) { togglePlayback() })
    }

    private fun renderPlayer() {
        val entry = playingEntry ?: run { body.addView(emptyState(getString(R.string.nothing_playing))); return }
        val track = entry.getJSONObject("track")
        body.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(32), dp(32), dp(32), dp(24))
            addView(TextView(this@MainActivity).apply {
                text = track.optString("album").ifBlank { getString(R.string.unknown_album) }
                textSize = 20f; setTextColor(FOG); gravity = Gravity.CENTER; setBackgroundColor(IRON)
            }, LinearLayout.LayoutParams(-1, 0, 1f).apply { bottomMargin = dp(20) })
            addView(label(track.getString("title"), 22f, WHITE, true).apply { gravity = Gravity.CENTER })
            addView(label(track.optString("artist").ifBlank { getString(R.string.unknown_artist) }, 18f, FOG).apply { gravity = Gravity.CENTER })
            addView(SeekBar(this@MainActivity).apply {
                max = if (prepared) player?.duration ?: 0 else 0; progress = if (prepared) player?.currentPosition ?: 0 else 0
                contentDescription = getString(R.string.playback_position)
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(bar: SeekBar?, value: Int, fromUser: Boolean) { if (fromUser && prepared) player?.seekTo(value) }
                    override fun onStartTrackingTouch(bar: SeekBar?) = Unit
                    override fun onStopTrackingTouch(bar: SeekBar?) = Unit
                })
            }, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(20) })
            addView(primary(getString(if (player?.isPlaying == true) R.string.pause else R.string.play)) { togglePlayback() }, LinearLayout.LayoutParams(-1, dp(56)))
        })
    }

    private fun scheduleProgress() {
        handler.removeCallbacksAndMessages(null)
        if (prepared && player?.isPlaying == true) handler.postDelayed({ if (screen == Screen.PLAYER) render(); scheduleProgress() }, 1000)
    }

    private fun renderConnections() {
        val container = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(20), dp(20), dp(32)) }
        body.addView(container)
        container.addView(label(getString(R.string.connections), 24f, WHITE, true))
        container.addView(label(getString(R.string.connections_explanation), 15f, FOG).apply { setPadding(0, dp(8), 0, dp(20)) })
        container.addView(label(getString(R.string.registered_libraries), 14f, FOG, true))
        task {
            val count = JSONArray(call("hosts")).length()
            onUi { if (screen == Screen.CONNECTIONS) {
                container.addView(label(resources.getQuantityString(R.plurals.library_count, count, count), 18f, WHITE).apply { setPadding(0, dp(8), 0, dp(20)) })
                container.addView(primary(getString(R.string.register_connection)) { invitationDialog() }, LinearLayout.LayoutParams(-1, dp(56)))
            } }
        }
    }

    private fun invitationDialog() {
        val input = EditText(this).apply { hint = getString(R.string.invitation_hint); minLines = 4 }
        AlertDialog.Builder(this).setTitle(R.string.register_connection).setView(input).setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.continue_action) { _, _ ->
                val invitation = input.text.toString()
                try {
                    require(invitation.length <= 16 * 1024) { getString(R.string.invitation_too_long) }
                    val host = JSONObject(invitation).getString("host")
                    require(host.matches(Regex("[0-9a-f]{64}"))) { getString(R.string.invalid_host_id) }
                    AlertDialog.Builder(this).setTitle(R.string.confirm_library).setMessage(getString(R.string.confirm_library_message, host))
                        .setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.register) { _, _ -> register(invitation, host) }.show()
                } catch (error: Exception) { showStatus(error.message ?: getString(R.string.invalid_invitation), true) }
            }.show()
    }

    private fun register(invitation: String, host: String) = task {
        val socket = onMainAddress(host)
        call("enroll", JSONObject().put("invitation", invitation).put("socket", socket))
        call("refresh", JSONObject().put("host", host).put("socket", socket))
        loadCatalog()
        onUi { showStatus(getString(R.string.connection_registered)); navigate(Screen.LIBRARY) }
    }

    private fun availableHosts(): JSONArray {
        val hosts = JSONArray(call("hosts")); check(hosts.length() > 0) { getString(R.string.register_first) }
        val result = CompletableFuture<JSONArray>()
        runOnUiThread {
            val available = JSONArray()
            for (index in 0 until hosts.length()) addresses[hosts.getString(index)]?.let { available.put(JSONObject().put("host", hosts.getString(index)).put("socket", it)) }
            if (available.length() == 0) result.completeExceptionally(IllegalStateException(getString(R.string.library_offline))) else result.complete(available)
        }
        return result.get()
    }

    private fun onMainAddress(host: String): String {
        val result = CompletableFuture<String>()
        runOnUiThread { addresses[host]?.let(result::complete) ?: result.completeExceptionally(IllegalStateException(getString(R.string.library_offline))) }
        return result.get()
    }

    private fun conflictCard() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(16), dp(16), dp(16)); setBackgroundColor(CARBON)
        addView(label(resources.getQuantityString(R.plurals.conflict_count, conflicts.length(), conflicts.length()), 16f, WHITE, true))
        addView(label(getString(R.string.conflict_explanation), 14f, FOG).apply { setPadding(0, dp(4), 0, 0) })
    }

    private fun emptyState(message: String) = LinearLayout(this).apply {
        gravity = Gravity.CENTER; setPadding(dp(32), dp(64), dp(32), dp(32)); addView(label(message, 18f, FOG).apply { gravity = Gravity.CENTER })
    }

    private fun label(value: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = value; textSize = size; setTextColor(color); if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun action(value: String, callback: () -> Unit) = Button(this).apply {
        text = value; setTextColor(WHITE); setBackgroundColor(Color.TRANSPARENT); minWidth = dp(48); minHeight = dp(48)
        setOnClickListener { callback() }; controls.add(this)
    }

    private fun primary(value: String, callback: () -> Unit) = action(value, callback).apply { setBackgroundColor(BLUE) }
    private fun showStatus(message: String, error: Boolean = false) { status.text = message; status.setTextColor(if (error) 0xffff8a80.toInt() else WHITE); status.visibility = View.VISIBLE }

    private fun task(action: () -> Unit) {
        if (busy) return
        busy = true; controls.forEach { it.isEnabled = false }
        worker.execute {
            try { action() } catch (error: Exception) { onUi { showStatus(error.cause?.message ?: error.message ?: getString(R.string.operation_failed), true); render() } }
            finally { onUi { busy = false; controls.forEach { it.isEnabled = true } } }
        }
    }

    private fun requestAudioFocus(): Boolean {
        val audio = getSystemService(AudioManager::class.java)
        if (focus == null) focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
            .setOnAudioFocusChangeListener { change -> if (change != AudioManager.AUDIOFOCUS_GAIN && prepared && player?.isPlaying == true) { player?.pause(); onUi { render() } } }.build()
        return audio.requestAudioFocus(requireNotNull(focus)) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun onUi(action: () -> Unit) = runOnUiThread { if (!isDestroyed) action() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    override fun onStop() { if (prepared && player?.isPlaying == true) player?.pause(); super.onStop() }
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null); if (::discovery.isInitialized) discovery.stop(); player?.release()
        focus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }; super.onDestroy()
    }
}
