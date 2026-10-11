#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Candidate {
    pub id: String,
    pub track: String,
    pub source: String,
    pub context: String,
    pub asset: String,
    pub parents: Vec<String>,
}

impl crate::artwork::Candidate {
    fn key(&self) -> (&str, &str, &str) {
        (&self.track, &self.source, &self.context)
    }
}

#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Artwork {
    #[serde(with = "crate::artwork::assets")]
    pub assets: std::collections::BTreeMap<String, Vec<u8>>,
    pub candidates: Vec<crate::artwork::Candidate>,
    pub preferred: std::collections::BTreeMap<String, String>,
}

impl crate::artwork::Artwork {
    pub fn merge(&mut self, incoming: &Self) -> anyhow::Result<()> {
        for (id, bytes) in &incoming.assets {
            anyhow::ensure!(
                self.assets.get(id).is_none_or(|old| old == bytes),
                "conflicting image asset"
            );
            self.assets.insert(id.clone(), bytes.clone());
        }
        for candidate in &incoming.candidates {
            if let Some(old) = self.candidates.iter().find(|c| c.id == candidate.id) {
                anyhow::ensure!(old == candidate, "conflicting image revision");
            } else {
                self.candidates.push(candidate.clone());
            }
        }
        for (key, asset) in &incoming.preferred {
            self.preferred
                .entry(key.clone())
                .or_insert_with(|| asset.clone());
        }
        Ok(())
    }

    pub fn validate(&self, tracks: &std::collections::BTreeSet<&str>) -> anyhow::Result<()> {
        use sha2::Digest as _;
        anyhow::ensure!(
            self.assets.len() <= 100000 && self.candidates.len() <= 200000,
            "artwork too large"
        );
        for (id, bytes) in &self.assets {
            anyhow::ensure!(
                bytes.len() <= 512 * 1024
                    && hex::encode(sha2::Sha256::digest(bytes)) == *id
                    && crate::artwork::bounded_jpeg(bytes),
                "invalid image asset"
            );
        }
        let records: std::collections::BTreeMap<_, _> =
            self.candidates.iter().map(|c| (&c.id, c)).collect();
        anyhow::ensure!(
            records.len() == self.candidates.len(),
            "duplicate image revision"
        );
        let mut remaining = std::collections::BTreeMap::new();
        let mut children = std::collections::BTreeMap::<_, Vec<_>>::new();
        for candidate in &self.candidates {
            anyhow::ensure!(
                tracks.contains(candidate.track.as_str())
                    && self.assets.contains_key(&candidate.asset)
                    && candidate.id.len() <= 128
                    && candidate.context.len() <= 4096
                    && candidate.parents.len() <= 10000
                    && ["embedded", "folder", "music", "legacy"]
                        .contains(&candidate.source.as_str()),
                "invalid image candidate"
            );
            let parents: std::collections::BTreeSet<_> = candidate.parents.iter().collect();
            anyhow::ensure!(
                parents.len() == candidate.parents.len(),
                "duplicate image parent"
            );
            remaining.insert(&candidate.id, candidate.parents.len());
            for parent in &candidate.parents {
                anyhow::ensure!(
                    records
                        .get(parent)
                        .is_some_and(|p| p.key() == candidate.key()),
                    "invalid image parent"
                );
                children.entry(parent).or_default().push(&candidate.id);
            }
        }
        let mut ready: Vec<_> = self
            .candidates
            .iter()
            .filter(|c| c.parents.is_empty())
            .map(|c| &c.id)
            .collect();
        let mut index = 0;
        while index < ready.len() {
            let id = ready[index];
            index += 1;
            for child in children.get(id).into_iter().flatten() {
                let count = remaining.get_mut(child).expect("validated image revision");
                *count -= 1;
                if *count == 0 {
                    ready.push(child);
                }
            }
        }
        anyhow::ensure!(ready.len() == self.candidates.len(), "image revision cycle");
        Ok(())
    }
}

pub(crate) fn bounded_jpeg(bytes: &[u8]) -> bool {
    if bytes.len() > 512 * 1024 || !bytes.ends_with(&[0xff, 0xd9]) {
        return false;
    }
    let mut decoder = jpeg_decoder::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_max_decoding_buffer_size(400 * 400 * 4);
    if decoder.read_info().is_err() {
        return false;
    }
    if !decoder
        .info()
        .is_some_and(|info| (1..=400).contains(&info.width) && (1..=400).contains(&info.height))
    {
        return false;
    }
    decoder.decode().is_ok()
}

mod assets {
    pub fn serialize<S: serde::Serializer>(
        value: &std::collections::BTreeMap<String, Vec<u8>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        use base64::Engine as _;
        use serde::Serialize as _;
        let encoded: std::collections::BTreeMap<_, _> = value
            .iter()
            .map(|(id, data)| (id, base64::engine::general_purpose::STANDARD.encode(data)))
            .collect();
        encoded.serialize(serializer)
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<std::collections::BTreeMap<String, Vec<u8>>, D::Error> {
        use base64::Engine as _;
        use serde::Deserialize as _;
        let encoded = std::collections::BTreeMap::<String, String>::deserialize(deserializer)?;
        encoded
            .into_iter()
            .map(|(id, value)| {
                base64::engine::general_purpose::STANDARD
                    .decode(value)
                    .map(|data| (id, data))
                    .map_err(serde::de::Error::custom)
            })
            .collect()
    }
}
