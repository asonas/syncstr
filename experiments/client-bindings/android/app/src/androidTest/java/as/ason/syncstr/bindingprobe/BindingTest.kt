package `as`.ason.syncstr.bindingprobe

import kotlinx.coroutines.*
import uniffi.syncstr_binding_probe.*

class BindingTest : android.app.Instrumentation() {
    override fun onCreate(arguments: android.os.Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        try {
            checkArm64Bindings()
            finish(android.app.Activity.RESULT_OK, android.os.Bundle().apply {
                putString("stream", "PASS ARM64: typed values/errors, Main dispatcher, cancellation, disposal, shutdown/reopen")
            })
        } catch (failure: Throwable) {
            finish(android.app.Activity.RESULT_CANCELED, android.os.Bundle().apply {
                putString("stream", "FAIL ARM64: ${failure.stackTraceToString()}")
            })
        }
    }

    private fun checkArm64Bindings() = runBlocking {
        check(android.os.Build.SUPPORTED_ABIS.contains("arm64-v8a"))
        val directory = java.io.File(targetContext.cacheDir, "binding-${System.nanoTime()}")
        check(directory.mkdir())
        val path = java.io.File(directory, "synthetic.lockfile").absolutePath
        try {
            withContext(Dispatchers.Main) {
                Client.open(path).use { client ->
                    val pin = PinnedTrack("logical-track-a", "shared-audio")
                    check(client.catalog() == CatalogView(7uL, listOf(pin, PinnedTrack("logical-track-b", "shared-audio"))))
                    try { Client.open(path).close(); error("duplicate profile accepted") }
                    catch (_: ProbeException.ProfileUnavailable) { }
                    try { client.prepare(PinnedTrack("", "hash")); error("invalid pin accepted") }
                    catch (_: ProbeException.InvalidPin) { }
                    client.prepare(pin).use { check(it.complete() == pin) }
                    check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
                    supervisorScope {
                        client.prepare(pin).use { operation ->
                            val pending = async { operation.complete() }
                            withTimeout(5000) { while (!operation.hasStarted()) yield() }
                            operation.cancel()
                            try { pending.await(); error("late result accepted") }
                            catch (_: ProbeException.Cancelled) { }
                        }
                    }
                    client.shutdown()
                    Client.open(path).use { it.shutdown() }
                    try { client.prepare(pin); error("closed client accepted") }
                    catch (_: ProbeException.Closed) { }
                }
                Client.open(path).use { check(it.catalog().tracks.size == 2) }
                Client.open(path).use { it.shutdown() }
            }
        } finally {
            check(java.io.File(path).delete())
            check(directory.delete())
        }
    }
}
