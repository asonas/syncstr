//! D5 evidence for an already-created, stopped backup. No backup writes.
use super::*;

// Subcomponents make external credentials and not-yet-implemented control material explicit.
const REQUIRED: &[&str] = &[
    "catalog-history",
    "sqlite-sidecars",
    "identity-membership",
    "peer-state",
    "tls-identity",
    "administrative-secrets",
    "audio",
    "artwork",
    "identity-mappings",
    "configuration",
    "trust-pins",
    "relay-settings",
    "installed-build-profiles",
    "control-journal",
    "minimum-profile-floor",
    "maintenance-state",
    "manifests",
    "client-intent",
];
const OPTIONAL: &[&str] = &[
    "sqlite-sidecars",
    "relay-settings",
    "control-journal",
    "minimum-profile-floor",
    "maintenance-state",
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Input {
    version: u8,
    cluster: String,
    root: PathBuf,
    stopped_and_fenced: bool,
    expected_hosts: BTreeSet<String>,
    expected_members: BTreeSet<String>,
    hosts: BTreeMap<String, BackupHost>,
    clients: BTreeSet<String>,
    components: BTreeMap<String, Declaration>,
    custody: CustodyAssertions,
    /// Optional earlier file expectations; never a replacement for database asset references.
    #[serde(default)]
    expected_files: BTreeMap<String, FileEvidence>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BackupHost {
    host: String,
    data: String,
    build: String,
    profiles: BTreeSet<String>,
    evidence: BTreeMap<String, String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case", deny_unknown_fields)]
enum Declaration {
    Present {
        paths: BTreeSet<String>,
    },
    Absent,
    /// The explanation is in the private checklist, never copied into the manifest.
    NotApplicable {
        reason_digest: String,
    },
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CustodyAssertions {
    process_exit_and_exclusive_ownership: bool,
    encrypted_separate_storage: bool,
    encrypted_offline_copy: bool,
    key_held_separately_by_owner: bool,
    custodian_and_access_confirmed: bool,
    /// SHA-256 of the private checklist naming destinations, custody, access and retention.
    checklist_digest: String,
}

#[derive(Serialize)]
struct SemanticEvidence {
    /// Top-level map/array entries; scalar evidence has count 1.
    count: usize,
    sha256: String,
}

#[derive(Serialize)]
pub(super) struct Manifest {
    version: u8,
    cluster: String,
    stopped_and_fenced: bool,
    /// Always false: decryption and stopped restore require separate execution.
    backup_verified: bool,
    components: BTreeMap<String, Declaration>,
    custody_assertions: CustodyAssertions,
    files: BTreeMap<String, FileEvidence>,
    semantics: BTreeMap<String, BTreeMap<String, SemanticEvidence>>,
    comparison: Comparison,
    blocking: BTreeSet<String>,
}

pub(super) fn manifest(input: Input) -> anyhow::Result<Manifest> {
    anyhow::ensure!(
        input.version == VERSION && input.stopped_and_fenced,
        "version 1 and stopped/fenced backup required"
    );
    anyhow::ensure!(
        input.custody.process_exit_and_exclusive_ownership,
        "operator process-exit and exclusive-ownership evidence required"
    );
    anyhow::ensure!(
        valid_digest(&input.custody.checklist_digest),
        "invalid private checklist digest"
    );
    anyhow::ensure!(
        input
            .components
            .keys()
            .all(|k| REQUIRED.contains(&k.as_str())),
        "unknown D5 component"
    );
    anyhow::ensure!(
        std::fs::symlink_metadata(&input.root)?.is_dir(),
        "backup root must be a real directory"
    );
    let before = snapshot(&input.root)?;
    let mut blocking = BTreeSet::new();
    for name in REQUIRED {
        match input.components.get(*name) {
            None => {
                blocking.insert(format!("undeclared-component:{name}"));
            }
            Some(Declaration::Absent) => {
                blocking.insert(format!("absent-component:{name}"));
            }
            Some(Declaration::NotApplicable { reason_digest }) => {
                anyhow::ensure!(
                    valid_digest(reason_digest),
                    "not-applicable requires a private explanation digest"
                );
                if !OPTIONAL.contains(name) {
                    blocking.insert(format!("required-component-not-applicable:{name}"));
                }
            }
            Some(Declaration::Present { paths }) => {
                if paths.is_empty() {
                    blocking.insert(format!("empty-component:{name}"));
                }
                for path in paths {
                    relative(path)?;
                    if !before.contains_key(&format!("root/{path}"))
                        && !before.contains_key(&format!("root/{path}/"))
                    {
                        blocking.insert(format!("missing-component-path:{name}:{path}"));
                    }
                }
            }
        }
    }
    for (path, expected) in &input.expected_files {
        relative(path)?;
        anyhow::ensure!(
            valid_digest(&expected.sha256),
            "invalid expected file digest"
        );
        match before.get(&format!("root/{path}")) {
            None => {
                blocking.insert(format!("missing-file:{path}"));
            }
            Some(actual) if actual.evidence != *expected => {
                blocking.insert(format!("corrupt-file:{path}"));
            }
            _ => {}
        }
    }
    for (name, asserted) in [
        (
            "encrypted-separate-storage",
            input.custody.encrypted_separate_storage,
        ),
        (
            "encrypted-offline-copy",
            input.custody.encrypted_offline_copy,
        ),
        (
            "key-held-separately-by-owner",
            input.custody.key_held_separately_by_owner,
        ),
        (
            "custodian-and-access-confirmed",
            input.custody.custodian_and_access_confirmed,
        ),
    ] {
        if !asserted {
            blocking.insert(format!("unconfirmed-custody:{name}"));
        }
    }
    let mut reports = Vec::new();
    let mut semantics = BTreeMap::new();
    for (name, descriptor) in input.hosts {
        relative(&name)?;
        relative(&descriptor.data)?;
        let mut evidence = BTreeMap::new();
        for (label, path) in descriptor.evidence {
            relative(&label)?;
            relative(&path)?;
            evidence.insert(label, input.root.join(path));
        }
        let report = match host(HostInput {
            version: VERSION,
            host: descriptor.host,
            cluster: input.cluster.clone(),
            data: input.root.join(descriptor.data),
            build: descriptor.build,
            profiles: descriptor.profiles,
            evidence,
            stopped_and_fenced: true,
        }) {
            Ok(report) => report,
            Err(_) => {
                // Preserve the complete file manifest, including sidecars, without opening them writable.
                blocking.insert(format!("uninspectable-host:{name}"));
                continue;
            }
        };
        let mut categories = report.categories.clone();
        categories.insert("membership".into(), serde_json::to_value(&report.proof)?);
        categories.insert("baseline".into(), json!(report.baseline));
        categories.insert("schema".into(), json!(report.schema));
        let summary = categories
            .into_iter()
            .map(|(key, value)| {
                let count = if value.get("present") == Some(&Value::Bool(false)) {
                    0
                } else if let Some(rows) = value.get("count").and_then(Value::as_u64) {
                    usize::try_from(rows)?
                } else {
                    match &value {
                        Value::Object(v) => v.len(),
                        Value::Array(v) => v.len(),
                        Value::Null => 0,
                        _ => 1,
                    }
                };
                Ok((
                    key,
                    SemanticEvidence {
                        count,
                        sha256: semantic_digest(&value)?,
                    },
                ))
            })
            .collect::<anyhow::Result<BTreeMap<_, _>>>()?;
        semantics.insert(name, summary);
        reports.push(report);
    }
    let clients = input
        .clients
        .iter()
        .map(|p| {
            relative(p)?;
            Ok(input.root.join(p))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let comparison = compare_reports(
        Collection {
            version: VERSION,
            cluster: input.cluster.clone(),
            expected_hosts: input.expected_hosts,
            expected_members: input.expected_members,
            hosts: vec![],
            clients,
        },
        reports,
    )?;
    blocking.extend(comparison.blocking.iter().cloned());
    anyhow::ensure!(
        before == snapshot(&input.root)?,
        "backup source changed during manifest generation"
    );
    let files = before
        .into_iter()
        .filter_map(|(path, file)| {
            path.strip_prefix("root/")
                .filter(|p| !p.ends_with('/'))
                .map(|p| (p.to_owned(), file.evidence))
        })
        .collect();
    Ok(Manifest {
        version: VERSION,
        cluster: input.cluster,
        stopped_and_fenced: true,
        backup_verified: false,
        components: input.components,
        custody_assertions: input.custody,
        files,
        semantics,
        comparison,
        blocking,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(root: &Path) -> anyhow::Result<Input> {
        let host = super::super::tests::fixture(root)?;
        let components = REQUIRED
            .iter()
            .map(|name| {
                (
                    (*name).into(),
                    Declaration::Present {
                        paths: BTreeSet::from(["data".into()]),
                    },
                )
            })
            .collect();
        Ok(Input {
            version: 1,
            cluster: host.cluster,
            root: root.to_owned(),
            stopped_and_fenced: true,
            expected_hosts: BTreeSet::from([host.host.clone()]),
            expected_members: BTreeSet::from([host.host.clone()]),
            hosts: BTreeMap::from([(
                "host-a".into(),
                BackupHost {
                    host: host.host,
                    data: "data".into(),
                    build: host.build,
                    profiles: host.profiles,
                    evidence: BTreeMap::from([("identity".into(), "private.key".into())]),
                },
            )]),
            clients: BTreeSet::new(),
            components,
            custody: CustodyAssertions {
                process_exit_and_exclusive_ownership: true,
                encrypted_separate_storage: true,
                encrypted_offline_copy: true,
                key_held_separately_by_owner: true,
                custodian_and_access_confirmed: true,
                checklist_digest: digest(b"fictional-private-checklist"),
            },
            expected_files: BTreeMap::new(),
        })
    }

    #[test]
    fn manifest_preserves_stopped_backup_and_redacts_authority() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let descriptor = input(root.path())?;
        let before = snapshot(root.path())?;
        let result = manifest(descriptor)?;
        assert!(before == snapshot(root.path())?);
        assert!(result.files.contains_key("private.key"));
        assert!(result.files.contains_key("data/staging/upload-retained"));
        assert!(result.semantics["host-a"].contains_key("membership"));
        assert!(!result.backup_verified);
        let output = canonical(&serde_json::to_value(result)?)?;
        assert!(!output.contains("fictional-secret-do-not-print"));
        assert!(!output.contains(root.path().to_str().expect("temporary path")));
        Ok(())
    }

    #[test]
    fn manifest_requires_d5_declarations_and_custody_assertions() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let mut descriptor = input(root.path())?;
        descriptor.components.remove("peer-state");
        descriptor
            .components
            .insert("identity-membership".into(), Declaration::Absent);
        descriptor.components.insert(
            "control-journal".into(),
            Declaration::NotApplicable {
                reason_digest: digest(b"not implemented in fixture"),
            },
        );
        descriptor.components.insert(
            "tls-identity".into(),
            Declaration::NotApplicable {
                reason_digest: digest(b"cannot omit required authority"),
            },
        );
        descriptor.custody.encrypted_offline_copy = false;
        let result = manifest(descriptor)?;
        for expected in [
            "undeclared-component:peer-state",
            "absent-component:identity-membership",
            "required-component-not-applicable:tls-identity",
            "unconfirmed-custody:encrypted-offline-copy",
        ] {
            assert!(result.blocking.contains(expected));
        }
        assert!(
            !result
                .blocking
                .contains("required-component-not-applicable:control-journal")
        );
        Ok(())
    }

    #[test]
    fn manifest_detects_missing_corrupt_files_and_unresolved_requests() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let mut descriptor = input(root.path())?;
        descriptor.components.insert(
            "audio".into(),
            Declaration::Present {
                paths: BTreeSet::from(["missing.wav".into()]),
            },
        );
        descriptor.expected_files.insert(
            "missing.wav".into(),
            FileEvidence {
                bytes: 1,
                sha256: digest(b"x"),
            },
        );
        descriptor.expected_files.insert(
            "private.key".into(),
            FileEvidence {
                bytes: 1,
                sha256: digest(b"x"),
            },
        );
        let report = host(HostInput {
            version: 1,
            host: descriptor.hosts["host-a"].host.clone(),
            cluster: descriptor.cluster.clone(),
            data: root.path().join("data"),
            build: "fixture-build".into(),
            profiles: BTreeSet::new(),
            evidence: BTreeMap::new(),
            stopped_and_fenced: true,
        })?;
        let export = ClientExport {
            version: 1,
            cluster: descriptor.cluster.clone(),
            member: report.host.clone(),
            baseline: report.baseline,
            build: "fixture-reader".into(),
            queue: FileEvidence {
                bytes: 2,
                sha256: digest(b"[]"),
            },
            queue_path: "queue.json".into(),
            requests: vec![ClientRequest {
                operation: "register-track".into(),
                id: "uncertain".into(),
                digest: digest(b"intent"),
                target_host: report.host.clone(),
                state: IntentState::OutcomeUnknown,
                eligibility: None,
                receipts: BTreeSet::new(),
                staging: BTreeSet::new(),
            }],
            staging: BTreeMap::new(),
        };
        std::fs::write(root.path().join("queue.json"), b"[]")?;
        std::fs::write(
            root.path().join("intent.json"),
            serde_json::to_vec(&export)?,
        )?;
        descriptor.clients.insert("intent.json".into());
        let result = manifest(descriptor)?;
        assert!(
            result
                .blocking
                .contains("missing-component-path:audio:missing.wav")
        );
        assert!(result.blocking.contains("missing-file:missing.wav"));
        assert!(result.blocking.contains("corrupt-file:private.key"));
        assert!(result.blocking.contains(&format!(
            "unresolved-client-request:{}:uncertain",
            report.host
        )));
        Ok(())
    }

    #[test]
    fn manifest_rejects_escaping_paths_and_unfenced_sources() -> anyhow::Result<()> {
        let first = tempfile::tempdir()?;
        let mut descriptor = input(first.path())?;
        descriptor
            .hosts
            .get_mut("host-a")
            .expect("fixture host")
            .data = "../outside".into();
        assert!(manifest(descriptor).is_err());
        let second = tempfile::tempdir()?;
        let mut descriptor = input(second.path())?;
        descriptor.stopped_and_fenced = false;
        assert!(manifest(descriptor).is_err());
        Ok(())
    }

    #[test]
    fn manifest_is_canonical_across_backup_roots() -> anyhow::Result<()> {
        let first = tempfile::tempdir()?;
        let second = tempfile::tempdir()?;
        let one = input(first.path())?;
        let two = input(second.path())?;
        for path in snapshot(first.path())?.keys().filter(|p| !p.ends_with('/')) {
            let relative = path.strip_prefix("root/").expect("source-relative file");
            std::fs::copy(first.path().join(relative), second.path().join(relative))?;
        }
        assert_eq!(
            canonical(&serde_json::to_value(manifest(one)?)?)?,
            canonical(&serde_json::to_value(manifest(two)?)?)?
        );
        Ok(())
    }

    #[test]
    fn manifest_retains_sidecars_and_blocks_uninspectable_hosts() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let descriptor = input(root.path())?;
        std::fs::write(
            root.path().join("data/node.sqlite-wal"),
            b"fictional-retained-wal",
        )?;
        let before = snapshot(root.path())?;
        let result = manifest(descriptor)?;
        assert!(result.files.contains_key("data/node.sqlite-wal"));
        assert!(result.blocking.contains("uninspectable-host:host-a"));
        assert!(before == snapshot(root.path())?);
        Ok(())
    }

    #[test]
    fn manifest_detects_database_referenced_audio_and_retains_orphans() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let descriptor = input(root.path())?;
        let data = root.path().join("data");
        let baseline = digest(&serde_json::to_vec(&crate::shared_audio::legacy(
            &readonly(&data)?,
        )?)?);
        drop(crate::shared_audio::Store::activate(&data, &baseline)?);
        let missing = digest(b"missing-original");
        let corrupt = digest(b"expected-original");
        let connection = rusqlite::Connection::open(data.join("node.sqlite"))?;
        connection.execute(
            "INSERT INTO shared_objects VALUES (?, 16, 'missing.wav')",
            [&missing],
        )?;
        connection.execute(
            "INSERT INTO shared_objects VALUES (?, 17, 'corrupt.wav')",
            [&corrupt],
        )?;
        drop(connection);
        std::fs::write(data.join("objects/corrupt.wav"), b"bad")?;
        std::fs::write(data.join("objects/orphan.wav"), b"retained")?;
        let result = manifest(descriptor)?;
        assert!(result.files.contains_key("data/objects/orphan.wav"));
        assert!(
            result
                .blocking
                .iter()
                .any(|v| v.contains(&format!("missing-audio:{missing}")))
        );
        assert!(
            result
                .blocking
                .iter()
                .any(|v| v.contains(&format!("corrupt-audio:{corrupt}:corrupt.wav")))
        );
        let host = result
            .comparison
            .availability
            .values()
            .next()
            .expect("host evidence");
        assert!(
            host["local"]["unreferenced_objects"]
                .as_array()
                .expect("orphan paths")
                .contains(&json!("orphan.wav"))
        );
        Ok(())
    }
}
