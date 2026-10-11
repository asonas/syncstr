package `as`.ason.syncstr

import android.app.Instrumentation
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Real headless enrollment and Android playback, with a separate offline run. */
class PlaybackCheck : Instrumentation() {
    private lateinit var arguments: Bundle

    override fun onCreate(args: Bundle?) { arguments = requireNotNull(args); start() }

    override fun onStart() {
        val results = Bundle()
        var discovery: LanDiscovery? = null
        var player: MediaPlayer? = null
        try {
            val key = DeviceKey(targetContext).load()
            val root = targetContext.filesDir.resolve("library").path
            fun call(operation: String, args: JSONObject = JSONObject()) = Native.run(root, key, operation, args.toString())
            val objectId = requireNotNull(arguments.getString("object"))
            if (arguments.getString("phase") == "online") {
                val invitation = String(Base64.decode(requireNotNull(arguments.getString("invitation")), Base64.NO_WRAP), Charsets.UTF_8)
                val host = JSONObject(invitation).getString("host")
                val found = CountDownLatch(1)
                var socket: String? = null
                discovery = LanDiscovery(targetContext) { id, address -> if (id == host && address != null) { socket = address; found.countDown() } }
                runOnMainSync { discovery?.start() }
                check(found.await(20, TimeUnit.SECONDS)) { "LAN host not discovered" }
                call("enroll", JSONObject().put("invitation", invitation).put("socket", socket))
                val catalog = JSONObject(call("refresh", JSONObject().put("host", host).put("socket", socket)))
                check((0 until catalog.getJSONArray("entries").length()).any { catalog.getJSONArray("entries").getJSONObject(it).getString("sha256") == objectId }) { "Fixture missing from catalog" }
                check(call("local-file", JSONObject().put("object", objectId)) == "null") { "Catalog refresh downloaded unselected audio" }
                call("download", JSONObject().put("addresses", org.json.JSONArray().put(JSONObject().put("host", host).put("socket", socket))).put("object", objectId))
            } else {
                check(arguments.getString("phase") == "offline") { "Unknown test phase" }
                check(JSONObject(call("catalog")).getJSONArray("entries").length() > 0) { "Catalog not restored" }
            }
            val path = org.json.JSONTokener(call("local-file", JSONObject().put("object", objectId))).nextValue() as? String
                ?: error("Verified local audio unavailable")
            val ready = CountDownLatch(1)
            val finished = CountDownLatch(1)
            var failure: String? = null
            Handler(Looper.getMainLooper()).post {
                player = MediaPlayer().apply {
                    setDataSource(path)
                    setOnPreparedListener { it.start(); ready.countDown() }
                    setOnErrorListener { _, what, extra -> failure = "Playback error $what/$extra"; ready.countDown(); true }
                    prepareAsync()
                }
            }
            check(ready.await(10, TimeUnit.SECONDS)) { "Playback prepare timed out" }
            check(failure == null) { requireNotNull(failure) }
            Thread.sleep(1000)
            runOnMainSync {
                check(player?.isPlaying == true && requireNotNull(player).currentPosition > 0) { "Playback did not advance" }
                finished.countDown()
            }
            check(finished.await(2, TimeUnit.SECONDS))
            results.putString("result", "${arguments.getString("phase")}: verified saved audio and advancing Android playback")
            finish(-1, results)
        } catch (error: Exception) {
            results.putString("error", error.message)
            finish(0, results)
        } finally {
            runOnMainSync { discovery?.stop(); player?.release() }
        }
    }
}
