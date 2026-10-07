pub const MAX_AUDIO: u64 = 20 * 1024 * 1024 * 1024;
pub const MAX_METADATA: usize = 1024 * 1024;

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    #[serde(default)]
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_art: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub track: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disc_number: Option<i64>,
    pub suffix: String,
    pub size: u64,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Entry {
    pub track: crate::model::Track,
    pub sha256: String,
    #[serde(
        default,
        with = "crate::model::artwork",
        skip_serializing_if = "Option::is_none"
    )]
    pub artwork: Option<Vec<u8>>,
}

impl crate::model::Entry {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.sha256.len() == 64
                && self
                    .sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "invalid content hash"
        );
        anyhow::ensure!(
            self.track.size > 0 && self.track.size <= crate::model::MAX_AUDIO,
            "invalid audio size"
        );
        anyhow::ensure!(!self.track.title.trim().is_empty(), "missing title");
        anyhow::ensure!(
            self.artwork.as_ref().map_or(0, Vec::len) <= 512 * 1024,
            "artwork too large"
        );
        anyhow::ensure!(
            matches!(
                self.track.suffix.as_str(),
                "mp3" | "m4a" | "aac" | "flac" | "wav" | "aiff" | "aif" | "alac"
            ),
            "unsupported suffix"
        );
        anyhow::ensure!(
            self.track
                .duration
                .is_none_or(|value| value.is_finite() && value >= 0.0),
            "invalid duration"
        );
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Catalog {
    pub id: String,
    pub name: String,
    pub entries: Vec<crate::model::Entry>,
}

mod artwork {
    pub fn serialize<S: serde::Serializer>(
        value: &Option<Vec<u8>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        use base64::Engine as _;
        use serde::Serialize as _;
        value
            .as_ref()
            .map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes))
            .serialize(serializer)
    }

    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<Vec<u8>>, D::Error> {
        use base64::Engine as _;
        use serde::Deserialize as _;
        Option::<String>::deserialize(deserializer)?
            .map(|value| {
                base64::engine::general_purpose::STANDARD
                    .decode(value)
                    .map_err(serde::de::Error::custom)
            })
            .transpose()
    }
}
