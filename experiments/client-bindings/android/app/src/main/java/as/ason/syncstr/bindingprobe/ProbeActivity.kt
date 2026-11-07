package `as`.ason.syncstr.bindingprobe

class ProbeActivity : android.app.Activity() {
    override fun onCreate(state: android.os.Bundle?) {
        super.onCreate(state)
        setContentView(android.widget.TextView(this).apply { text = "Binding Probe: run instrumentation to verify ARM64 bindings." })
    }
}
