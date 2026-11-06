pub const DEFAULT_TRACK_COUNT: usize = 5_000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Track {
    pub id: usize,
    pub title: String,
    pub artist: String,
}

pub fn fixture_tracks(count: usize) -> Vec<Track> {
    let titles = [
        "Paper Lantern Orbit",
        "青い窓のワルツ",
        "Velvet Satellite Garden",
        "雨粒の地図",
        "Amber Clock Parade",
        "夜明けの紙飛行機",
        "Silver Teacup Echo",
        "星を編む午後",
        "Quiet Marble River",
        "風待ちのアトリエ",
    ];
    (0..count)
        .map(|id| Track {
            id,
            title: titles[id % titles.len()].to_owned(),
            artist: format!("Fictional Ensemble {}", id / titles.len() + 1),
        })
        .collect()
}

pub fn filtered_indices(tracks: &[Track], query: &str) -> Vec<usize> {
    let query = query.to_lowercase();
    tracks
        .iter()
        .enumerate()
        .filter_map(|(index, track)| track.title.to_lowercase().contains(&query).then_some(index))
        .collect()
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct PlaybackState {
    pub current_track_id: Option<usize>,
    pub is_playing: bool,
}

impl PlaybackState {
    pub fn toggle(&mut self, selected: Option<&Track>) {
        if self.is_playing {
            self.is_playing = false;
        } else if let Some(track) = selected {
            self.current_track_id = Some(track.id);
            self.is_playing = true;
        } else if self.current_track_id.is_some() {
            self.is_playing = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn fixtures_have_requested_count_and_unique_ids() {
        let tracks = fixture_tracks(DEFAULT_TRACK_COUNT);
        assert_eq!(tracks.len(), 5_000);
        assert_eq!(
            tracks
                .iter()
                .map(|track| track.id)
                .collect::<HashSet<_>>()
                .len(),
            5_000
        );
        assert!(fixture_tracks(0).is_empty());
        assert_eq!(fixture_tracks(13).len(), 13);
    }

    #[test]
    fn titles_repeat_every_ten_tracks_without_reusing_identity() {
        let tracks = fixture_tracks(30);
        for index in 0..20 {
            assert_eq!(tracks[index].title, tracks[index + 10].title);
            assert_ne!(tracks[index].id, tracks[index + 10].id);
        }
        assert_eq!(
            tracks[..10]
                .iter()
                .map(|track| &track.title)
                .collect::<HashSet<_>>()
                .len(),
            10
        );
    }

    #[test]
    fn search_matches_title_substrings_without_case() {
        let tracks = fixture_tracks(30);
        assert_eq!(filtered_indices(&tracks, "LANTERN"), vec![0, 10, 20]);
        assert_eq!(filtered_indices(&tracks, "lantern"), vec![0, 10, 20]);
        assert!(filtered_indices(&tracks, "Fictional Ensemble").is_empty());
    }

    #[test]
    fn search_supports_japanese_titles() {
        let tracks = fixture_tracks(20);
        assert_eq!(filtered_indices(&tracks, "雨粒"), vec![3, 13]);
        assert_eq!(filtered_indices(&tracks, "星を編む午後"), vec![7, 17]);
    }

    #[test]
    fn empty_query_returns_every_track_and_missing_query_returns_none() {
        let tracks = fixture_tracks(10);
        assert_eq!(filtered_indices(&tracks, ""), (0..10).collect::<Vec<_>>());
        assert!(filtered_indices(&tracks, "missing title").is_empty());
        assert!(filtered_indices(&[], "").is_empty());
    }

    #[test]
    fn playback_retains_identity_when_paused_or_results_are_empty() {
        let tracks = fixture_tracks(11);
        let mut playback = PlaybackState::default();
        playback.toggle(None);
        assert_eq!(playback, PlaybackState::default());
        playback.toggle(Some(&tracks[10]));
        assert_eq!(playback.current_track_id, Some(10));
        assert!(playback.is_playing);
        playback.toggle(Some(&tracks[0]));
        assert!(!playback.is_playing);
        assert_eq!(playback.current_track_id, Some(10));
        playback.toggle(None);
        assert!(playback.is_playing);
        assert_eq!(playback.current_track_id, Some(10));
    }
}
