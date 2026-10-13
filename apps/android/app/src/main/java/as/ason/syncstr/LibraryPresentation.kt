package `as`.ason.syncstr

data class MusicItem(val objectId: String, val albumId: String?, val album: String,
    val artist: String, val albumArtist: String?, val title: String, val disc: Int, val number: Int)

data class MusicGroup(val id: String, val title: String, val credit: String, val members: List<MusicItem>)

object LibraryPresentation {
    fun groups(items: List<MusicItem>, albums: Boolean): List<MusicGroup> = items
        .groupBy { if (albums) it.albumId?.let { id -> "album:$id" } ?: "object:${it.objectId}" else it.artist }
        .map { (id, members) ->
            val ordered = members.sortedWith(compareBy<MusicItem>(
                { it.disc.takeIf { number -> number > 0 } ?: 1 },
                { it.number.takeIf { number -> number > 0 } ?: Int.MAX_VALUE },
                { it.title.lowercase(java.util.Locale.ROOT) }, { it.objectId }))
            val albumArtists = ordered.map { it.albumArtist }.distinct()
            val credit = albumArtists.singleOrNull()?.takeIf { it.isNotBlank() && !it.equals("Various Artists", true) }
                ?: ordered.map { it.artist }.distinct().joinToString(", ")
            MusicGroup(id, if (albums) ordered.first().album else id, credit, ordered)
        }.sortedWith(compareBy({ it.title.lowercase(java.util.Locale.ROOT) }, { it.id }))
}
