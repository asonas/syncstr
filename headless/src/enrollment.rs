const DOMAIN: &str = "syncstr-enrollment-grant-v1\n";

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Invitation {
    pub version: u8,
    pub cluster: String,
    pub host: String,
    pub secret: String,
    pub expires: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Grant {
    pub version: u8,
    pub id: String,
    pub cluster: String,
    pub issuer: String,
    pub member: String,
    pub host: bool,
    pub authority: Option<String>,
    pub signature: String,
}

impl crate::enrollment::Grant {
    fn signing_bytes(&self) -> anyhow::Result<Vec<u8>> {
        let payload = serde_json::to_string(&(
            self.version,
            &self.cluster,
            &self.issuer,
            &self.member,
            self.host,
            &self.authority,
        ))?;
        Ok(format!("{}{payload}", crate::enrollment::DOMAIN).into_bytes())
    }

    /// Verifies the signature, not the issuer's membership or host authority.
    pub fn verify_signature(&self) -> anyhow::Result<()> {
        use sha2::Digest as _;
        anyhow::ensure!(self.version == 1, "unsupported enrollment grant");
        anyhow::ensure!(
            self.id == hex::encode(sha2::Sha256::digest(self.signing_bytes()?)),
            "grant content identity mismatch"
        );
        uuid::Uuid::parse_str(&self.cluster)?;
        let issuer: iroh::EndpointId = self.issuer.parse()?;
        let _: iroh::EndpointId = self.member.parse()?;
        let signature: [u8; 64] = hex::decode(&self.signature)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid enrollment signature"))?;
        issuer.verify(
            &self.signing_bytes()?,
            &iroh::Signature::from_bytes(&signature),
        )?;
        Ok(())
    }
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Proof {
    pub root: String,
    pub grants: Vec<crate::enrollment::Grant>,
    pub revocations: Vec<crate::enrollment::Revocation>,
}

impl crate::enrollment::Proof {
    pub(crate) fn chain(&self, id: &str) -> anyhow::Result<Vec<&crate::enrollment::Grant>> {
        anyhow::ensure!(self.grants.len() <= 4096, "membership proof too large");
        let mut records = std::collections::HashMap::new();
        for grant in &self.grants {
            anyhow::ensure!(
                records.insert(grant.id.as_str(), grant).is_none(),
                "duplicate grant identity"
            );
        }
        let leaf = *records
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("missing member grant"))?;
        let mut grant = leaf;
        let mut seen = std::collections::HashSet::new();
        let mut chain = Vec::new();
        loop {
            anyhow::ensure!(
                seen.len() < 32 && seen.insert(&grant.id),
                "cyclic or deep membership proof"
            );
            grant.verify_signature()?;
            chain.push(grant);
            anyhow::ensure!(grant.cluster == leaf.cluster, "cross-cluster grant");
            match &grant.authority {
                None => {
                    anyhow::ensure!(
                        grant.issuer == self.root && grant.member == self.root && grant.host,
                        "untrusted cluster root"
                    );
                    return Ok(chain);
                }
                Some(id) => {
                    let parent = *records
                        .get(id.as_str())
                        .ok_or_else(|| anyhow::anyhow!("missing issuer grant"))?;
                    anyhow::ensure!(
                        parent.member == grant.issuer && parent.host,
                        "issuer is not a library host"
                    );
                    grant = parent;
                }
            }
        }
    }

    pub fn verify(&self, id: &str) -> anyhow::Result<&crate::enrollment::Grant> {
        let chain = self.chain(id)?;
        let (active, disputed) = self.revocation_state()?;
        let member = chain[0];
        anyhow::ensure!(
            !disputed.contains(&member.member),
            "membership conflict requires user resolution"
        );
        for index in active {
            let revoked = &self.revocations[index];
            anyhow::ensure!(revoked.member != member.member, "member revoked");
            for grant in &chain {
                anyhow::ensure!(
                    grant.issuer != revoked.member || revoked.observed.contains(&grant.id),
                    "grant issued beyond revocation boundary"
                );
            }
        }
        anyhow::ensure!(
            chain.iter().all(|grant| !disputed.contains(&grant.issuer)),
            "disputed issuer authority"
        );
        Ok(member)
    }

    pub fn membership_conflicts(&self) -> anyhow::Result<std::collections::BTreeSet<String>> {
        Ok(self.revocation_state()?.1)
    }

    pub(crate) fn revocation_state(
        &self,
    ) -> anyhow::Result<(Vec<usize>, std::collections::BTreeSet<String>)> {
        anyhow::ensure!(
            self.revocations.len() <= 256,
            "revocation history too large"
        );
        let mut unique: std::collections::HashSet<_> =
            self.grants.iter().map(|grant| grant.id.as_str()).collect();
        let mut chains = Vec::new();
        for revocation in &self.revocations {
            revocation.verify_signature()?;
            anyhow::ensure!(unique.insert(&revocation.id), "duplicate membership record");
            let chain = self.chain(&revocation.authority)?;
            anyhow::ensure!(
                chain[0].member == revocation.issuer
                    && chain[0].host
                    && chain[0].cluster == revocation.cluster,
                "revocation issuer is not a host"
            );
            chains.push(chain);
        }
        let mut blockers = vec![Vec::new(); self.revocations.len()];
        for (i, record) in self.revocations.iter().enumerate() {
            for (j, revoked) in self.revocations.iter().enumerate() {
                if i != j
                    && ((record.issuer == revoked.member && !revoked.observed.contains(&record.id))
                        || chains[i].iter().any(|grant| {
                            grant.issuer == revoked.member && !revoked.observed.contains(&grant.id)
                        }))
                {
                    blockers[i].push(j);
                }
            }
        }
        let mut state = vec![None; self.revocations.len()];
        loop {
            let mut changed = false;
            for (i, blocked_by) in blockers.iter().enumerate() {
                if state[i].is_some() {
                    continue;
                }
                if blocked_by.iter().any(|j| state[*j] == Some(true)) {
                    state[i] = Some(false);
                    changed = true;
                } else if blocked_by.iter().all(|j| state[*j] == Some(false)) {
                    state[i] = Some(true);
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
        let mut active = Vec::new();
        let mut disputed = std::collections::BTreeSet::new();
        for (index, valid) in state.into_iter().enumerate() {
            match valid {
                Some(true) => active.push(index),
                Some(false) => {}
                None => {
                    disputed.insert(self.revocations[index].issuer.clone());
                    disputed.insert(self.revocations[index].member.clone());
                }
            }
        }
        Ok((active, disputed))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Revocation {
    pub version: u8,
    pub id: String,
    pub cluster: String,
    pub issuer: String,
    pub member: String,
    pub authority: String,
    pub observed: Vec<String>,
    pub change_heads: Vec<String>,
    pub signature: String,
}

impl crate::enrollment::Revocation {
    fn signing_bytes(&self) -> anyhow::Result<Vec<u8>> {
        Ok(format!(
            "syncstr-membership-revocation-v1\n{}",
            serde_json::to_string(&(
                self.version,
                &self.cluster,
                &self.issuer,
                &self.member,
                &self.authority,
                &self.observed,
                &self.change_heads,
            ))?
        )
        .into_bytes())
    }

    fn verify_signature(&self) -> anyhow::Result<()> {
        use sha2::Digest as _;
        anyhow::ensure!(
            self.version == 1 && self.observed.len() <= 4352 && self.change_heads.len() <= 64,
            "invalid revocation"
        );
        anyhow::ensure!(
            self.id == hex::encode(sha2::Sha256::digest(self.signing_bytes()?)),
            "revocation content identity mismatch"
        );
        uuid::Uuid::parse_str(&self.cluster)?;
        let issuer: iroh::EndpointId = self.issuer.parse()?;
        let _: iroh::EndpointId = self.member.parse()?;
        let mut unique = std::collections::HashSet::new();
        for id in self.observed.iter().chain(&self.change_heads) {
            anyhow::ensure!(
                id.len() == 64 && hex::decode(id)?.len() == 32,
                "invalid revocation observation"
            );
            anyhow::ensure!(unique.insert(id), "duplicate revocation observation");
        }
        let signature: [u8; 64] = hex::decode(&self.signature)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid revocation signature"))?;
        issuer.verify(
            &self.signing_bytes()?,
            &iroh::Signature::from_bytes(&signature),
        )?;
        Ok(())
    }
}

pub(crate) fn read_proof(
    connection: &rusqlite::Connection,
) -> anyhow::Result<crate::enrollment::Proof> {
    let root = connection.query_row(
        "SELECT root FROM cluster_trust WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    let mut statement =
        connection.prepare("SELECT payload FROM cluster_enrollment_grants ORDER BY id")?;
    let grants = statement
        .query_map([], |row| row.get::<_, Vec<u8>>(0))?
        .map(|row| Ok(serde_json::from_slice(&row?)?))
        .collect::<anyhow::Result<Vec<_>>>()?;
    let mut statement =
        connection.prepare("SELECT payload FROM cluster_revocations ORDER BY id")?;
    let revocations = statement
        .query_map([], |row| row.get::<_, Vec<u8>>(0))?
        .map(|row| Ok(serde_json::from_slice(&row?)?))
        .collect::<anyhow::Result<Vec<_>>>()?;
    Ok(crate::enrollment::Proof {
        root,
        grants,
        revocations,
    })
}

pub(crate) fn migrate(connection: &rusqlite::Connection) -> anyhow::Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS cluster_invitations (
        digest TEXT PRIMARY KEY, cluster TEXT NOT NULL, issuer TEXT NOT NULL,
        created INTEGER NOT NULL, expires INTEGER NOT NULL, host INTEGER NOT NULL, authority TEXT NOT NULL,
        grant_payload BLOB);
        CREATE TABLE IF NOT EXISTS cluster_enrollment_grants (
        id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS cluster_revocations (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS cluster_trust (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), root TEXT NOT NULL, local_grant TEXT NOT NULL);",
    )?;
    Ok(())
}

impl crate::store::Store {
    pub async fn cluster_membership_proof(&self) -> anyhow::Result<crate::enrollment::Proof> {
        self.run(|connection, _| crate::enrollment::read_proof(connection))
            .await
    }

    pub async fn revoke_cluster_member(
        &self,
        identity: &crate::peer::Identity,
        member: String,
    ) -> anyhow::Result<crate::enrollment::Revocation> {
        use sha2::Digest as _;
        let _: iroh::EndpointId = member.parse()?;
        let authority = self.local_cluster_grant(identity).await?;
        let proof = self.cluster_membership_proof().await?;
        anyhow::ensure!(
            proof.grants.iter().any(|grant| grant.member == member),
            "unknown member"
        );
        let mut observed: Vec<_> = proof
            .grants
            .iter()
            .filter(|record| record.issuer == member)
            .map(|record| record.id.clone())
            .chain(
                proof
                    .revocations
                    .iter()
                    .filter(|record| record.issuer == member)
                    .map(|record| record.id.clone()),
            )
            .collect();
        observed.sort();
        let changes = self.cluster_changes().await?;
        let superseded: std::collections::HashSet<_> =
            changes.iter().flat_map(|record| &record.previous).collect();
        let mut change_heads: Vec<_> = changes
            .iter()
            .filter(|record| record.author == member && !superseded.contains(&record.id))
            .map(|record| record.id.clone())
            .collect();
        change_heads.sort();
        let mut record = crate::enrollment::Revocation {
            version: 1,
            id: String::new(),
            cluster: authority.cluster,
            issuer: identity.id().to_string(),
            member,
            authority: authority.id,
            observed,
            change_heads,
            signature: String::new(),
        };
        record.id = hex::encode(sha2::Sha256::digest(record.signing_bytes()?));
        record.signature = hex::encode(identity.sign(&record.signing_bytes()?));
        record.verify_signature()?;
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            proof.verify(&record.authority)?;
            transaction.execute(
                "INSERT OR IGNORE INTO cluster_revocations VALUES (?, ?)",
                rusqlite::params![record.id, serde_json::to_vec(&record)?],
            )?;
            transaction.commit()?;
            Ok(record)
        })
        .await
    }

    pub async fn merge_cluster_membership(
        &self,
        incoming: crate::enrollment::Proof,
    ) -> anyhow::Result<()> {
        self.merge_cluster_membership_from(None, incoming).await
    }

    pub async fn authenticate_cluster_peer(
        &self,
        presenter: String,
        incoming: crate::enrollment::Proof,
    ) -> anyhow::Result<()> {
        self.merge_cluster_membership_from(Some(presenter.clone()), incoming)
            .await?;
        let proof = self.cluster_membership_proof().await?;
        anyhow::ensure!(
            proof
                .grants
                .iter()
                .any(|grant| grant.member == presenter && proof.verify(&grant.id).is_ok()),
            "peer revoked or disputed"
        );
        Ok(())
    }

    async fn merge_cluster_membership_from(
        &self,
        presenter: Option<String>,
        incoming: crate::enrollment::Proof,
    ) -> anyhow::Result<()> {
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let mut combined = crate::enrollment::read_proof(&transaction)?;
            anyhow::ensure!(combined.root == incoming.root, "cluster root mismatch");
            let cluster: String = transaction.query_row(
                "SELECT id FROM cluster_identity WHERE singleton = 1",
                [],
                |row| row.get(0),
            )?;
            for grant in incoming.grants {
                anyhow::ensure!(grant.cluster == cluster, "cross-cluster grant");
                if let Some(existing) = combined.grants.iter().find(|record| record.id == grant.id)
                {
                    anyhow::ensure!(*existing == grant, "inconsistent grant replay");
                } else {
                    transaction.execute(
                        "INSERT INTO cluster_enrollment_grants VALUES (?, ?)",
                        rusqlite::params![grant.id, serde_json::to_vec(&grant)?],
                    )?;
                    combined.grants.push(grant);
                }
            }
            if let Some(presenter) = presenter {
                anyhow::ensure!(
                    combined.grants.iter().any(
                        |grant| grant.member == presenter && combined.verify(&grant.id).is_ok()
                    ),
                    "unauthorized cluster peer"
                );
            }
            for record in incoming.revocations {
                anyhow::ensure!(record.cluster == cluster, "cross-cluster revocation");
                if let Some(existing) = combined
                    .revocations
                    .iter()
                    .find(|existing| existing.id == record.id)
                {
                    anyhow::ensure!(*existing == record, "inconsistent revocation replay");
                } else {
                    transaction.execute(
                        "INSERT INTO cluster_revocations VALUES (?, ?)",
                        rusqlite::params![record.id, serde_json::to_vec(&record)?],
                    )?;
                    combined.revocations.push(record);
                }
            }
            for grant in &combined.grants {
                combined.chain(&grant.id)?;
            }
            combined.revocation_state()?;
            transaction.commit()?;
            Ok(())
        })
        .await
    }

    pub(crate) async fn local_cluster_grant(
        &self,
        identity: &crate::peer::Identity,
    ) -> anyhow::Result<crate::enrollment::Grant> {
        use sha2::Digest as _;
        let cluster = self
            .cluster_inventory()
            .await?
            .cluster
            .ok_or_else(|| anyhow::anyhow!("create or join a cluster first"))?;
        anyhow::ensure!(
            cluster.member_id == identity.id().to_string(),
            "cluster belongs to another identity"
        );
        let mut genesis = crate::enrollment::Grant {
            version: 1,
            id: String::new(),
            cluster: cluster.id,
            issuer: cluster.member_id.clone(),
            member: cluster.member_id,
            host: true,
            authority: None,
            signature: String::new(),
        };
        genesis.id = hex::encode(sha2::Sha256::digest(genesis.signing_bytes()?));
        genesis.signature = hex::encode(identity.sign(&genesis.signing_bytes()?));
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let inserted = transaction.execute(
                "INSERT OR IGNORE INTO cluster_trust VALUES (1, ?, ?)",
                rusqlite::params![genesis.member, genesis.id],
            )?;
            if inserted == 1 {
                transaction.execute(
                    "INSERT INTO cluster_enrollment_grants VALUES (?, ?)",
                    rusqlite::params![genesis.id, serde_json::to_vec(&genesis)?],
                )?;
            }
            let local: String = transaction.query_row(
                "SELECT local_grant FROM cluster_trust WHERE singleton = 1",
                [],
                |row| row.get(0),
            )?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            let grant = proof.verify(&local)?.clone();
            anyhow::ensure!(
                grant.member == genesis.member && grant.host,
                "local member is not a library host"
            );
            transaction.commit()?;
            Ok(grant)
        })
        .await
    }

    pub async fn join_cluster(
        &self,
        identity: &crate::peer::Identity,
        inviter: iroh::EndpointId,
        grant_id: String,
        proof: crate::enrollment::Proof,
    ) -> anyhow::Result<()> {
        let grant = proof.verify(&grant_id)?.clone();
        anyhow::ensure!(
            grant.member == identity.id().to_string()
                && grant.issuer == inviter.to_string()
                && grant.authority.is_some(),
            "enrollment identity mismatch"
        );
        for record in &proof.grants {
            anyhow::ensure!(record.cluster == grant.cluster, "cross-cluster grant");
            proof.chain(&record.id)?;
        }
        anyhow::ensure!(
            proof
                .revocations
                .iter()
                .all(|record| record.cluster == grant.cluster),
            "cross-cluster revocation"
        );
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            transaction.execute(
                "INSERT OR IGNORE INTO cluster_identity VALUES (1, ?, ?)",
                rusqlite::params![grant.cluster, grant.member],
            )?;
            let existing: (String, String) = transaction.query_row(
                "SELECT id, member_id FROM cluster_identity WHERE singleton = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            anyhow::ensure!(
                existing == (grant.cluster, grant.member),
                "already belongs to another cluster"
            );
            transaction.execute(
                "INSERT OR IGNORE INTO cluster_trust VALUES (1, ?, ?)",
                rusqlite::params![proof.root, grant_id],
            )?;
            let existing: (String, String) = transaction.query_row(
                "SELECT root, local_grant FROM cluster_trust WHERE singleton = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            anyhow::ensure!(
                existing == (proof.root, grant_id),
                "membership is already bound to another grant"
            );
            for record in proof.grants {
                let payload = serde_json::to_vec(&record)?;
                transaction.execute(
                    "INSERT OR IGNORE INTO cluster_enrollment_grants VALUES (?, ?)",
                    rusqlite::params![record.id, payload],
                )?;
                let stored: Vec<u8> = transaction.query_row(
                    "SELECT payload FROM cluster_enrollment_grants WHERE id = ?",
                    [record.id],
                    |row| row.get(0),
                )?;
                anyhow::ensure!(payload == stored, "inconsistent grant replay");
            }
            for record in proof.revocations {
                let payload = serde_json::to_vec(&record)?;
                transaction.execute(
                    "INSERT OR IGNORE INTO cluster_revocations VALUES (?, ?)",
                    rusqlite::params![record.id, payload],
                )?;
                let stored: Vec<u8> = transaction.query_row(
                    "SELECT payload FROM cluster_revocations WHERE id = ?",
                    [record.id],
                    |row| row.get(0),
                )?;
                anyhow::ensure!(payload == stored, "inconsistent revocation replay");
            }
            transaction.commit()?;
            Ok(())
        })
        .await
    }

    pub async fn create_cluster_invitation(
        &self,
        identity: &crate::peer::Identity,
        host: bool,
        now: u64,
        lifetime: u64,
    ) -> anyhow::Result<crate::enrollment::Invitation> {
        use sha2::Digest as _;
        anyhow::ensure!(
            (1..=3600).contains(&lifetime),
            "invitation lifetime must be at most one hour"
        );
        let expires = now
            .checked_add(lifetime)
            .filter(|value| *value <= i64::MAX as u64)
            .ok_or_else(|| anyhow::anyhow!("invalid invitation time"))?;
        let secret = hex::encode(rand::random::<[u8; 32]>());
        let digest = hex::encode(sha2::Sha256::digest(secret.as_bytes()));
        let issuer = identity.id().to_string();
        let authority = self.local_cluster_grant(identity).await?.id;
        let relay = self.cluster_relay().await?;
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let (cluster, member): (String, String) = transaction.query_row(
                "SELECT id, member_id FROM cluster_identity WHERE singleton = 1", [],
                |row| Ok((row.get(0)?, row.get(1)?)))?;
            anyhow::ensure!(member == issuer, "cluster belongs to another identity");
            transaction.execute("INSERT INTO cluster_invitations (digest, cluster, issuer, created, expires, host, authority) VALUES (?, ?, ?, ?, ?, ?, ?)",
                rusqlite::params![digest, cluster, issuer, now as i64, expires as i64, host, authority])?;
            transaction.commit()?;
            Ok(crate::enrollment::Invitation { version: 1, cluster, host: issuer, secret, expires, relay })
        }).await
    }

    pub async fn redeem_cluster_invitation(
        &self,
        identity: &crate::peer::Identity,
        secret: &str,
        member: String,
        now: u64,
    ) -> anyhow::Result<crate::enrollment::Grant> {
        use sha2::Digest as _;
        anyhow::ensure!(
            secret.len() == 64 && now <= i64::MAX as u64,
            "invalid invitation"
        );
        let peer: iroh::EndpointId = member.parse()?;
        anyhow::ensure!(peer != identity.id(), "cannot enroll this host itself");
        let digest = hex::encode(sha2::Sha256::digest(secret.as_bytes()));
        let issuer = identity.id().to_string();
        let invitation = self.run({
            let digest = digest.clone();
            let issuer = issuer.clone();
            move |connection, _| {
                connection.query_row("SELECT cluster, host, authority FROM cluster_invitations WHERE digest = ? AND issuer = ? AND created <= ? AND expires > ? AND grant_payload IS NULL",
                    rusqlite::params![digest, issuer, now as i64, now as i64],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?, row.get::<_, String>(2)?))).map_err(Into::into)
            }
        }).await?;
        let mut grant = crate::enrollment::Grant {
            version: 1,
            id: String::new(),
            cluster: invitation.0,
            issuer,
            member,
            host: invitation.1,
            authority: Some(invitation.2),
            signature: String::new(),
        };
        grant.id = hex::encode(sha2::Sha256::digest(grant.signing_bytes()?));
        grant.signature = hex::encode(identity.sign(&grant.signing_bytes()?));
        grant.verify_signature()?;
        self.run(move |connection, _| {
            let transaction = connection.transaction()?;
            let proof = crate::enrollment::read_proof(&transaction)?;
            let authority = proof.verify(grant.authority.as_deref().unwrap())?;
            anyhow::ensure!(authority.member == grant.issuer && authority.host, "inviter is not a library host");
            let payload = serde_json::to_vec(&grant)?;
            let changed = transaction.execute("UPDATE cluster_invitations SET grant_payload = ? WHERE digest = ? AND grant_payload IS NULL AND created <= ? AND expires > ?",
                rusqlite::params![payload, digest, now as i64, now as i64])?;
            anyhow::ensure!(changed == 1, "invitation expired or already consumed");
            transaction.execute("INSERT OR IGNORE INTO cluster_enrollment_grants VALUES (?, ?)", rusqlite::params![grant.id, payload])?;
            transaction.commit()?;
            Ok(grant)
        }).await
    }
}
