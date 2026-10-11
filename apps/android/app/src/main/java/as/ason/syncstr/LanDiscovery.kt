package `as`.ason.syncstr

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address

class LanDiscovery(context: Context, private val changed: (String, String?) -> Unit) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<NsdServiceInfo>()
    private val services = mutableMapOf<String, String>()
    private var resolving = false
    private var stopped = false
    private var started = false
    private val listener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(type: String) { handler.post { started = true; if (stopped) manager.stopServiceDiscovery(this) } }
        override fun onDiscoveryStopped(type: String) { handler.post { started = false } }
        override fun onStartDiscoveryFailed(type: String, code: Int) { handler.post { started = false } }
        override fun onStopDiscoveryFailed(type: String, code: Int) { handler.post { started = false } }
        override fun onServiceFound(service: NsdServiceInfo) { handler.post { if (!stopped) { pending.add(service); resolveNext() } } }
        override fun onServiceLost(service: NsdServiceInfo) { handler.post {
            services.remove(service.serviceName)?.let { changed(it, null) }
            pending.removeAll { it.serviceName == service.serviceName }
        } }
    }

    fun start() { manager.discoverServices("_syncstr-cluster._udp.", NsdManager.PROTOCOL_DNS_SD, listener) }
    fun stop() {
        stopped = true
        pending.clear()
        if (started) manager.stopServiceDiscovery(listener)
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (stopped || resolving || pending.isEmpty()) return
        val service = pending.removeFirst()
        resolving = true
        manager.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, code: Int) { handler.post { resolving = false; resolveNext() } }
            override fun onServiceResolved(info: NsdServiceInfo) { handler.post {
                resolving = false
                val id = info.attributes["id"]?.toString(Charsets.UTF_8)
                val version = info.attributes["version"]?.toString(Charsets.UTF_8)
                val ip = info.host
                if (!stopped && version == "1" && id?.matches(Regex("[0-9a-f]{64}")) == true && ip is Inet4Address && info.port > 0) {
                    services[info.serviceName] = id
                    changed(id, "${ip.hostAddress}:${info.port}")
                }
                resolveNext()
            } }
        })
    }
}
