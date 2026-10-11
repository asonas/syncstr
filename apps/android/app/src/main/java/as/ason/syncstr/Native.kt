package `as`.ason.syncstr

object Native {
    init { System.loadLibrary("syncstr_android") }
    external fun run(root: String, key: ByteArray, operation: String, arguments: String): String
}
