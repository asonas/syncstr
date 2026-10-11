package `as`.ason.syncstr

internal object UiFormatting {
    fun clock(milliseconds: Int): String {
        val safe = milliseconds.coerceAtLeast(0)
        return "%d:%02d".format(safe / 60000, safe / 1000 % 60)
    }

    fun conflictReference(identifier: String): String = identifier.take(8)
}
