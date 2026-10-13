package `as`.ason.syncstr

import org.junit.Assert.assertEquals
import org.junit.Test

class LibraryPresentationTest {
    private fun item(id: String, albumId: String?, album: String = "Collection", artist: String = "Artist",
        disc: Int = 1, number: Int = 1) = MusicItem(id, albumId, album, artist, null, id, disc, number)

    @Test fun sameTitleAndCaseVariantsKeepEveryAlbumAndUnresolvedTrack() {
        val groups = LibraryPresentation.groups(listOf(item("a", "first"), item("b", "second"),
            item("c", "third", "collection"), item("d", null), item("e", null)), true)
        assertEquals(5, groups.size)
        assertEquals(setOf("a", "b", "c", "d", "e"), groups.flatMap { it.members }.map { it.objectId }.toSet())
    }

    @Test fun compilationCreditsIncludeAllArtists() {
        val group = LibraryPresentation.groups(listOf(item("b", "release", artist = "Beta"),
            item("a", "release", artist = "Alpha")), true).single()
        assertEquals("Alpha, Beta", group.credit)
        val credited = LibraryPresentation.groups(group.members.map { it.copy(albumArtist = "Ensemble") }, true).single()
        assertEquals("Ensemble", credited.credit)
    }

    @Test fun discsPrecedeTrackNumbersAndUnknownNumbersSortLast() {
        val groups = LibraryPresentation.groups(listOf(item("d2t1", "release", disc = 2),
            item("d1t2", "release", number = 2), item("unnumbered", "release", disc = 0, number = 0),
            item("d2t2", "release", disc = 2, number = 2), item("d1t1", "release")), true)
        assertEquals(listOf("d1t1", "d1t2", "unnumbered", "d2t1", "d2t2"), groups.single().members.map { it.objectId })
    }
}
