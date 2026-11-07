import uniffi.syncstr_binding_probe.*
import kotlinx.coroutines.*
import java.nio.file.Files
import java.util.concurrent.Executors

fun main() = runBlocking {
    val directory = Files.createTempDirectory("binding-probe")
    val path = directory.resolve("synthetic.lockfile").toString()
    val dispatcher = Executors.newSingleThreadExecutor { r -> Thread(r, "probe-ui") }.asCoroutineDispatcher()
    try {
        withContext(dispatcher) {
            Client.open(path).use { client ->
                try { Client.open(path).close(); error("duplicate profile accepted") }
                catch (_: ProbeException.ProfileUnavailable) { }
                try { client.prepare(PinnedTrack("", "hash")); error("invalid pin accepted") }
                catch (_: ProbeException.InvalidPin) { }
                val pin = PinnedTrack("logical-track-a", "shared-audio")
                check(client.catalog() == CatalogView(7uL, listOf(pin, PinnedTrack("logical-track-b", "shared-audio"))))
                client.prepare(pin).use { check(it.complete() == pin) }
                check(Thread.currentThread().name == "probe-ui")
                supervisorScope { client.prepare(pin).use { operation ->
                    val result = async { operation.complete() }
                    withTimeout(5000) { while (!operation.hasStarted()) { yield() } }
                    operation.cancel()
                    try { result.await(); error("late result accepted") }
                    catch (_: ProbeException.Cancelled) { }
                } }
                client.shutdown()
                Client.open(path).use { it.shutdown() }
                try { client.prepare(pin); error("closed client accepted") }
                catch (_: ProbeException.Closed) { }
            }
        }
        Client.open(path).use { check(it.catalog().tracks.size == 2) }
        Client.open(path).use { it.shutdown() }
        println("PASS Kotlin: typed pin/error, async executor return, explicit cancellation, disposal, shutdown/reopen")
    } finally {
        dispatcher.close()
        Files.deleteIfExists(directory.resolve("synthetic.lockfile"))
        Files.delete(directory)
    }
}
