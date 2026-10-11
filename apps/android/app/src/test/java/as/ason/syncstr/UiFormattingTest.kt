package `as`.ason.syncstr

import org.junit.Assert.assertEquals
import org.junit.Test

class UiFormattingTest {
    @Test fun clockFormatsMinutesAndSeconds() {
        assertEquals("0:00", UiFormatting.clock(0))
        assertEquals("1:05", UiFormatting.clock(65_999))
    }

    @Test fun clockDoesNotExposeNegativePlayerPositions() {
        assertEquals("0:00", UiFormatting.clock(-1))
    }

    @Test fun conflictReferencesDoNotExposeLongObjectIdentifiers() {
        assertEquals("01234567", UiFormatting.conflictReference("0123456789abcdef"))
    }
}
