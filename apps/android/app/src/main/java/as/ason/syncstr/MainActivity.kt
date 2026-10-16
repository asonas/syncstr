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
    private enum class BrowseMode { ALBUMS, ARTISTS, SONGS, HIDDEN }
    private enum class SaveState { REMOTE, DOWNLOADING, SAVED, FAILED }
    private data class LibrarySnapshot(val entries: JSONArray, val conflicts: JSONArray,
        val saved: Map<String, SaveState>, val hosts: Int?, val hostError: String?)

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
    private var browseMode = BrowseMode.ALBUMS
    private var player: MediaPlayer? = null
    private var playingEntry: JSONObject? = null
    private var prepared = false
    private var focus: AudioFocusRequest? = null
    private var busy = false
    private var playerSeek: SeekBar? = null
    private var playerTime: TextView? = null
    private var playerButton: Button? = null
    private var miniButton: Button? = null
    private var hostCount: Int? = null
    private var hostFailure: String? = null
    private var restoreId: String? = null
    private var restorePosition = 0
    private var restorePlaying = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        screen = state?.getString("screen")?.let { runCatching { Screen.valueOf(it) }.getOrNull() } ?: Screen.LIBRARY
        browseMode = state?.getString("browse")?.let { runCatching { BrowseMode.valueOf(it) }.getOrNull() } ?: BrowseMode.ALBUMS
        restoreId = state?.getString("playing")
        restorePosition = state?.getInt("position") ?: 0
        restorePlaying = state?.getBoolean("wasPlaying") ?: false
        window.statusBarColor = GRAPHITE
        window.navigationBarColor = CARBON
        buildChrome()
        try { key = DeviceKey(this).load() } catch (error: Exception) {
            showStatus(error.message ?: getString(R.string.identity_error), true)
            return
        }
        discovery = LanDiscovery(this) { id, socket -> if (socket == null) addresses.remove(id) else addresses[id] = socket }
        discovery.start()
        task {
            val snapshot = loadCatalog()
            val restored = restoreId?.let { id -> (0 until snapshot.entries.length()).map { snapshot.entries.getJSONObject(it) }.firstOrNull { it.getString("sha256") == id } }
            val restoredPath = restored?.let { entry ->
                org.json.JSONTokener(call("local-file", JSONObject().put("object", entry.getString("sha256")))).nextValue() as? String
            }
            return@task {
                applyCatalog(snapshot)
                if (catalog.length() == 0) showStatus(getString(R.string.empty_library_hint))
                if (restored != null && restoredPath != null) startPlayback(restoredPath, restored, restorePosition, restorePlaying)
            }
        }
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
        controls.add(this)
    }

    private fun navigate(target: Screen) { screen = target; render() }
    private fun call(operation: String, args: JSONObject = JSONObject()) = Native.run(filesDir.resolve("library").path, key, operation, args.toString())

    private fun loadCatalog(): LibrarySnapshot {
        val library = JSONObject(call("catalog"))
        val entries = library.getJSONArray("entries")
        var hosts: Int? = null
        var hostError: String? = null
        try {
            hosts = JSONArray(call("hosts")).length()
        } catch (error: Exception) {
            hostError = error.message ?: getString(R.string.operation_failed)
        }
        val saved = mutableMapOf<String, SaveState>()
        for (index in 0 until entries.length()) {
            val id = entries.getJSONObject(index).getString("sha256")
            val local = org.json.JSONTokener(call("local-file", JSONObject().put("object", id))).nextValue()
            saved[id] = if (local is String) SaveState.SAVED else SaveState.REMOTE
        }
        return LibrarySnapshot(entries, library.getJSONArray("conflicts"), saved, hosts, hostError)
    }

    private fun applyCatalog(snapshot: LibrarySnapshot) {
        catalog = snapshot.entries
        conflicts = snapshot.conflicts
        saveStates.clear(); saveStates.putAll(snapshot.saved)
        hostCount = snapshot.hosts; hostFailure = snapshot.hostError
    }

    private fun refreshLibrary() = task {
        val sources = availableHosts()
        var success = false
        var failure: Exception? = null
        for (index in 0 until sources.length()) try {
            call("refresh", sources.getJSONObject(index)); success = true
        } catch (error: Exception) { failure = error }
        if (!success) throw requireNotNull(failure)
        val snapshot = loadCatalog()
        return@task { applyCatalog(snapshot); showStatus(getString(R.string.library_updated)) }
    }

    private fun changeVisibility(album: String, hidden: Boolean) = task {
        call("visibility", JSONObject().put("album", album).put("hidden", hidden))
        var synced = false
        try {
            val sources = availableHosts()
            for (index in 0 until sources.length()) {
                try { call("refresh", sources.getJSONObject(index)); synced = true; break } catch (_: Exception) { }
            }
        } catch (_: Exception) { }
        val snapshot = loadCatalog()
        return@task { applyCatalog(snapshot); showStatus(getString(if (synced) R.string.library_updated else R.string.visibility_pending)) }
    }

    private fun render() {
        body.removeAllViews()
        miniPlayer.removeAllViews()
        controls.removeAll { it.parent == null }
        when (screen) {
            Screen.LIBRARY -> renderLibrary(false)
            Screen.SAVED -> renderLibrary(true)
            Screen.PLAYER -> renderPlayer()
            Screen.CONNECTIONS -> renderConnections()
        }
        renderMiniPlayer(false)
        controls.forEach { it.isEnabled = !busy }
        miniButton?.isEnabled = prepared && !busy
        playerButton?.isEnabled = prepared && !busy
    }

    private fun renderLibrary(savedOnly: Boolean) {
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(12), dp(20), dp(32)) }
        body.addView(ScrollView(this).apply { addView(list) })
        if (!savedOnly && conflicts.length() > 0) list.addView(conflictCard())
        val entries = (0 until catalog.length()).map { catalog.getJSONObject(it) }
            .filter { (it.optJSONObject("presentation")?.optBoolean("hidden", false) == true) == (browseMode == BrowseMode.HIDDEN) }
            .filter { !savedOnly || saveStates[it.getString("sha256")] == SaveState.SAVED }
        list.addView(LinearLayout(this).apply {
            addView(modeButton(getString(R.string.albums), BrowseMode.ALBUMS), LinearLayout.LayoutParams(0, dp(48), 1f))
            addView(modeButton(getString(R.string.artists), BrowseMode.ARTISTS), LinearLayout.LayoutParams(0, dp(48), 1f))
            addView(modeButton(getString(R.string.songs), BrowseMode.SONGS), LinearLayout.LayoutParams(0, dp(48), 1f))
        })
        list.addView(modeButton(getString(R.string.hidden_albums), BrowseMode.HIDDEN))
        if (entries.isEmpty()) {
            list.addView(emptyState(getString(if (browseMode == BrowseMode.HIDDEN) R.string.no_hidden_albums else if (savedOnly) R.string.no_saved_music else R.string.no_music)))
        }
        when (browseMode) {
            BrowseMode.ALBUMS, BrowseMode.HIDDEN -> renderGroups(list, entries, true)
            BrowseMode.ARTISTS -> renderGroups(list, entries, false)
            BrowseMode.SONGS -> entries.sortedBy { it.getJSONObject("track").getString("title").lowercase() }.forEach { list.addView(trackRow(it)) }
        }
    }

    private fun modeButton(text: String, mode: BrowseMode) = Button(this).apply {
        this.text = text
        setTextColor(WHITE)
        setBackgroundColor(if (browseMode == mode) BLUE else Color.TRANSPARENT)
        setOnClickListener { browseMode = mode; render() }
        controls.add(this)
    }

    private fun renderGroups(list: LinearLayout, entries: List<JSONObject>, albums: Boolean) {
        val byObject = entries.associateBy { it.getString("sha256") }
        val items = entries.map { entry ->
            val track = entry.getJSONObject("track")
            val presentation = entry.optJSONObject("presentation")
            MusicItem(entry.getString("sha256"), presentation?.optString("albumId")?.takeIf { it.isNotBlank() && it != "null" },
                presentation?.optString("album")?.takeIf { it.isNotBlank() && it != "null" } ?: albumName(entry),
                artistName(entry), presentation?.optString("albumArtist")?.takeIf { it.isNotBlank() && it != "null" },
                track.getString("title"), track.optInt("discNumber", 1), track.optInt("track", 0))
        }
        for (group in LibraryPresentation.groups(items, albums)) {
            list.addView(LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(24), 0, dp(8))
                addView(label(group.title, 21f, WHITE, true))
                val detail = if (albums) group.credit else resources.getQuantityString(R.plurals.track_count, group.members.size, group.members.size)
                addView(label(detail, 14f, FOG))
                if (albums) {
                    val album = group.members.first().albumId
                    if (album != null) addView(primary(getString(if (browseMode == BrowseMode.HIDDEN) R.string.unhide_album else R.string.hide_album)) {
                        changeVisibility(album, browseMode != BrowseMode.HIDDEN)
                    })
                }
            })
            group.members.forEach { list.addView(trackRow(byObject.getValue(it.objectId))) }
        }
    }

    private fun albumName(entry: JSONObject) = entry.getJSONObject("track").optString("album").ifBlank { getString(R.string.unknown_album) }
    private fun artistName(entry: JSONObject) = entry.getJSONObject("track").optString("artist").ifBlank { getString(R.string.unknown_artist) }

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
        if (busy) return
        val id = entry.getString("sha256")
        saveStates[id] = SaveState.DOWNLOADING
        render()
        task(onError = { saveStates[id] = SaveState.FAILED }) {
            call("download", JSONObject().put("object", id).put("addresses", availableHosts()))
            return@task {
                saveStates[id] = SaveState.SAVED
                showStatus(getString(R.string.saved_track, entry.getJSONObject("track").getString("title")))
            }
        }
    }

    private fun playSaved(entry: JSONObject) = task {
        val value = org.json.JSONTokener(call("local-file", JSONObject().put("object", entry.getString("sha256")))).nextValue()
        val path = value as? String ?: error(getString(R.string.saved_file_missing))
        return@task { startPlayback(path, entry) }
    }

    private fun startPlayback(path: String, entry: JSONObject, initialPosition: Int = 0, autoplay: Boolean = true) {
        handler.removeCallbacks(progressUpdate)
        val previous = player
        player = null
        prepared = false
        previous?.release()
        playingEntry = entry
        val replacement = MediaPlayer()
        player = replacement
        try {
            replacement.apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                setDataSource(path)
                setOnPreparedListener {
                    if (player !== it) return@setOnPreparedListener
                    prepared = true
                    if (initialPosition > 0) it.seekTo(initialPosition)
                    if (autoplay && hasWindowFocus() && requestAudioFocus()) it.start()
                    render(); scheduleProgress()
                }
                setOnCompletionListener { if (player === it) { render(); scheduleProgress() } }
                setOnErrorListener { failed, _, _ ->
                    if (player === failed) playbackFailed(failed)
                    true
                }
                prepareAsync()
            }
        } catch (_: java.io.IOException) {
            playbackFailed(replacement)
        } catch (_: IllegalArgumentException) {
            playbackFailed(replacement)
        } catch (_: IllegalStateException) {
            playbackFailed(replacement)
        }
        render()
    }

    private fun playbackFailed(failed: MediaPlayer) {
        if (player !== failed) return
        player = null
        prepared = false
        handler.removeCallbacks(progressUpdate)
        failed.release()
        showStatus(getString(R.string.playback_failed), true)
        render()
    }

    private fun togglePlayback() {
        if (!prepared) return
        val active = player ?: return
        if (active.isPlaying) active.pause() else if (requestAudioFocus()) active.start()
        updatePlaybackControls(); renderMiniPlayer(); scheduleProgress()
    }

    private fun renderMiniPlayer(clear: Boolean = true) {
        if (clear) miniPlayer.removeAllViews()
        val entry = playingEntry ?: run { miniPlayer.visibility = View.GONE; return }
        miniPlayer.visibility = View.VISIBLE
        val track = entry.getJSONObject("track")
        miniPlayer.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label(track.getString("title"), 15f, WHITE, true).apply { maxLines = 1 })
            addView(label(track.optString("artist").ifBlank { getString(R.string.unknown_artist) }, 13f, FOG).apply { maxLines = 1 })
        }, LinearLayout.LayoutParams(0, -2, 1f))
        miniButton = primary(getString(if (prepared && player?.isPlaying == true) R.string.pause else R.string.play)) { togglePlayback() }.apply { isEnabled = prepared && !busy }
        miniPlayer.addView(miniButton)
    }

    private fun renderPlayer() {
        val entry = playingEntry ?: run { body.addView(emptyState(getString(R.string.nothing_playing))); return }
        val track = entry.getJSONObject("track")
        body.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(32), dp(32), dp(32), dp(24))
            addView(TextView(this@MainActivity).apply {
                text = getString(R.string.artwork_unavailable)
                contentDescription = getString(R.string.artwork_unavailable_description, albumName(entry))
                textSize = 18f; setTextColor(FOG); gravity = Gravity.CENTER; setBackgroundColor(IRON)
            }, LinearLayout.LayoutParams(-1, 0, 1f).apply { bottomMargin = dp(20) })
            addView(label(track.getString("title"), 22f, WHITE, true).apply { gravity = Gravity.CENTER })
            addView(label(track.optString("artist").ifBlank { getString(R.string.unknown_artist) }, 18f, FOG).apply { gravity = Gravity.CENTER })
            playerSeek = SeekBar(this@MainActivity).apply {
                max = if (prepared) player?.duration ?: 0 else 0; progress = if (prepared) player?.currentPosition ?: 0 else 0
                contentDescription = getString(R.string.playback_position)
                setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(bar: SeekBar?, value: Int, fromUser: Boolean) { if (fromUser && prepared) player?.seekTo(value) }
                    override fun onStartTrackingTouch(bar: SeekBar?) = Unit
                    override fun onStopTrackingTouch(bar: SeekBar?) = Unit
                })
            }
            addView(playerSeek, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(20) })
            playerTime = label(formatTime(if (prepared) player?.currentPosition ?: 0 else 0, if (prepared) player?.duration ?: 0 else 0), 13f, FOG).apply { gravity = Gravity.CENTER }
            addView(playerTime)
            playerButton = primary(getString(if (prepared && player?.isPlaying == true) R.string.pause else R.string.play)) { togglePlayback() }.apply { isEnabled = prepared && !busy }
            addView(playerButton, LinearLayout.LayoutParams(-1, dp(56)))
        })
    }

    private fun scheduleProgress() {
        handler.removeCallbacks(progressUpdate)
        if (prepared && player?.isPlaying == true) handler.postDelayed(progressUpdate, 1000)
    }

    private val progressUpdate = object : Runnable {
        override fun run() {
            updatePlaybackControls()
            if (prepared && player?.isPlaying == true) handler.postDelayed(this, 1000)
        }
    }

    private fun updatePlaybackControls() {
        val active = player ?: return
        if (prepared) {
            playerSeek?.max = active.duration
            playerSeek?.progress = active.currentPosition
            playerTime?.text = formatTime(active.currentPosition, active.duration)
        }
        playerButton?.text = getString(if (prepared && active.isPlaying) R.string.pause else R.string.play)
    }

    private fun formatTime(position: Int, duration: Int): String {
        return getString(R.string.playback_time, UiFormatting.clock(position), UiFormatting.clock(duration))
    }

    private fun renderConnections() {
        val container = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(20), dp(20), dp(32)) }
        body.addView(container)
        container.addView(label(getString(R.string.connections), 24f, WHITE, true))
        container.addView(label(getString(R.string.connections_explanation), 15f, FOG).apply { setPadding(0, dp(8), 0, dp(20)) })
        container.addView(label(getString(R.string.registered_libraries), 14f, FOG, true))
        val detail = hostCount?.let { resources.getQuantityString(R.plurals.library_count, it, it) }
            ?: hostFailure ?: getString(R.string.loading_libraries)
        container.addView(label(detail, 18f, FOG).apply { setPadding(0, dp(8), 0, dp(20)) })
        container.addView(primary(getString(R.string.register_connection)) { invitationDialog() }, LinearLayout.LayoutParams(-1, dp(56)))
        if (hostFailure != null) container.addView(action(getString(R.string.retry)) {
            task { val snapshot = loadCatalog(); return@task { applyCatalog(snapshot) } }
        })
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
        val snapshot = loadCatalog()
        return@task { applyCatalog(snapshot); showStatus(getString(R.string.connection_registered)); screen = Screen.LIBRARY }
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
        val titles = (0 until conflicts.length()).take(5).map { index ->
            val id = conflicts.getString(index)
            (0 until catalog.length()).map { catalog.getJSONObject(it) }
                .firstOrNull { it.getString("sha256") == id }?.getJSONObject("track")?.getString("title")
                ?: getString(R.string.conflict_item, UiFormatting.conflictReference(id))
        }
        addView(label(titles.joinToString("\n"), 14f, WHITE).apply { setPadding(0, dp(8), 0, dp(8)) })
        addView(action(getString(R.string.refresh_conflicts)) { refreshLibrary() })
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

    private fun task(onError: (Exception) -> Unit = {}, action: () -> (() -> Unit)) {
        if (busy) return
        busy = true; controls.forEach { it.isEnabled = false }
        worker.execute {
            val completion = try { action() } catch (error: Exception) {
                { onError(error); showStatus(error.cause?.message ?: error.message ?: getString(R.string.operation_failed), true) }
            }
            onUi { busy = false; completion(); render() }
        }
    }

    private fun requestAudioFocus(): Boolean {
        val audio = getSystemService(AudioManager::class.java)
        if (focus == null) focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
            .setOnAudioFocusChangeListener { change -> onUi {
                if (change != AudioManager.AUDIOFOCUS_GAIN && prepared && player?.isPlaying == true) { player?.pause(); render() }
            } }.build()
        return audio.requestAudioFocus(requireNotNull(focus)) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun onUi(action: () -> Unit) = runOnUiThread { if (!isDestroyed) action() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("screen", screen.name)
        outState.putString("browse", browseMode.name)
        outState.putString("playing", playingEntry?.getString("sha256"))
        outState.putInt("position", if (prepared) player?.currentPosition ?: 0 else 0)
        outState.putBoolean("wasPlaying", prepared && player?.isPlaying == true)
        super.onSaveInstanceState(outState)
    }

    override fun onStart() { super.onStart(); if (::body.isInitialized && ::key.isInitialized) render() }
    override fun onStop() {
        if (prepared && player?.isPlaying == true) player?.pause()
        updatePlaybackControls()
        renderMiniPlayer()
        super.onStop()
    }
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null); if (::discovery.isInitialized) discovery.stop()
        val previous = player; player = null; prepared = false; previous?.release()
        focus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }; super.onDestroy()
    }
}
