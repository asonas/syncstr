#![cfg(feature = "p2p")]

#[tokio::test]
async fn client_observed_parents_preserve_a_concurrent_deletion() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let nodes = crate::hosts(root.path()).await?;
    let (host, store) = &nodes[0];
    let (object, import) = crate::fixture();
    let first = store.publish_cluster_change(host, object.clone(), import.clone()).await?;
    let deleted = store.publish_cluster_change(host, object.clone(), syncstr_headless::cluster_changes::Action::Delete).await?;
    let syncstr_headless::cluster_changes::Action::Import { entry, organization } = import else { unreachable!() };
    let edit = store.publish_observed_cluster_change(host, object.clone(), syncstr_headless::cluster_changes::Action::Edit { entry, organization }, vec![first.id]).await?;
    let mut expected = vec![deleted.id, edit.id];
    expected.sort();
    let mut heads: Vec<_> = store.cluster_object_states().await?[0].heads.iter().map(|record| record.id.clone()).collect();
    heads.sort();
    assert_eq!(heads, expected);
    assert!(store.cluster_selected_change(&object).await.is_err());
    Ok(())
}

#[tokio::test]
async fn late_revocation_reprojects_previously_accepted_changes_after_restart() -> anyhow::Result<()>
{
    let root = tempfile::tempdir()?;
    let nodes = crate::hosts(root.path()).await?;
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    let (hash, import) = crate::fixture();
    let first = a_store
        .publish_cluster_change(a, hash.clone(), import)
        .await?;
    b_store
        .apply_cluster_changes(a.id().to_string(), vec![first.clone()])
        .await?;
    a_store
        .publish_cluster_change(a, hash, syncstr_headless::cluster_changes::Action::Delete)
        .await?;
    b_store.revoke_cluster_member(b, a.id().to_string()).await?;
    a_store
        .merge_cluster_membership(b_store.cluster_membership_proof().await?)
        .await?;
    assert_eq!(
        a_store.cluster_object_states().await?[0].heads,
        vec![first.clone()]
    );
    assert_eq!(a_store.cluster_changes().await?.len(), 2);
    drop(nodes);
    let reopened = syncstr_headless::store::Store::open(&root.path().join("a/data"))?;
    assert_eq!(
        reopened.cluster_object_states().await?[0].heads,
        vec![first]
    );
    assert_eq!(reopened.cluster_changes().await?.len(), 2);
    Ok(())
}

#[tokio::test]
async fn revoked_history_catches_up_out_of_order_but_new_changes_stay_quarantined()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let nodes = crate::hosts(root.path()).await?;
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    let (hash, import) = crate::fixture();
    let first = a_store
        .publish_cluster_change(a, hash.clone(), import)
        .await?;
    let deleted = a_store
        .publish_cluster_change(
            a,
            hash.clone(),
            syncstr_headless::cluster_changes::Action::Delete,
        )
        .await?;
    b_store
        .apply_cluster_changes(a.id().to_string(), vec![first.clone(), deleted.clone()])
        .await?;
    b_store.revoke_cluster_member(b, a.id().to_string()).await?;
    let state = root.path().join("c/identity");
    syncstr_headless::peer::Identity::initialize(&state)?;
    let c = syncstr_headless::peer::Identity::open(&state)?;
    let c_store = syncstr_headless::store::Store::open(&root.path().join("c/data"))?;
    let invite = b_store
        .create_cluster_invitation(b, true, 1000, 600)
        .await?;
    let grant = b_store
        .redeem_cluster_invitation(b, &invite.secret, c.id().to_string(), 1100)
        .await?;
    c_store
        .join_cluster(
            &c,
            b.id(),
            grant.id,
            b_store.cluster_membership_proof().await?,
        )
        .await?;
    assert_eq!(
        c_store
            .receive_cluster_changes(b.id().to_string(), vec![deleted.clone()])
            .await?,
        1
    );
    assert!(c_store.cluster_changes().await?.is_empty());
    drop(c_store);
    let c_store = syncstr_headless::store::Store::open(&root.path().join("c/data"))?;
    assert_eq!(
        c_store
            .receive_cluster_changes(b.id().to_string(), vec![first])
            .await?,
        0
    );
    assert_eq!(
        c_store.cluster_object_states().await?[0].heads,
        vec![deleted.clone()]
    );
    let later = a_store
        .publish_cluster_change(
            a,
            hash,
            syncstr_headless::cluster_changes::Action::Resolve {
                selected: deleted.id.clone(),
            },
        )
        .await?;
    assert_eq!(
        c_store
            .receive_cluster_changes(b.id().to_string(), vec![later.clone()])
            .await?,
        1
    );
    assert_eq!(
        c_store.cluster_object_states().await?[0].heads,
        vec![deleted]
    );
    assert_eq!(
        c_store
            .receive_cluster_changes(b.id().to_string(), vec![later])
            .await?,
        1
    );
    assert_eq!(c_store.cluster_changes().await?.len(), 2);
    Ok(())
}

async fn hosts(
    root: &std::path::Path,
) -> anyhow::Result<
    Vec<(
        syncstr_headless::peer::Identity,
        syncstr_headless::store::Store,
    )>,
> {
    let mut nodes = Vec::new();
    for name in ["a", "b"] {
        let state = root.join(name).join("identity");
        syncstr_headless::peer::Identity::initialize(&state)?;
        nodes.push((
            syncstr_headless::peer::Identity::open(&state)?,
            syncstr_headless::store::Store::open(&root.join(name).join("data"))?,
        ));
    }
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    a_store.create_cluster(a.id().to_string()).await?;
    let invitation = a_store
        .create_cluster_invitation(a, true, 1000, 600)
        .await?;
    let grant = a_store
        .redeem_cluster_invitation(a, &invitation.secret, b.id().to_string(), 1100)
        .await?;
    b_store
        .join_cluster(
            b,
            a.id(),
            grant.id,
            a_store.cluster_membership_proof().await?,
        )
        .await?;
    Ok(nodes)
}

fn fixture() -> (String, syncstr_headless::cluster_changes::Action) {
    let entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json")).unwrap();
    let mut organization = syncstr_headless::organization::Organization::default();
    organization.import(&entry);
    (
        entry.sha256.clone(),
        syncstr_headless::cluster_changes::Action::Import {
            entry: Box::new(entry),
            organization: Box::new(organization),
        },
    )
}

#[tokio::test]
async fn stale_import_does_not_resurrect_a_deleted_object_and_replay_is_idempotent()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let nodes = crate::hosts(root.path()).await?;
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    let (hash, import) = crate::fixture();
    let first = a_store
        .publish_cluster_change(a, hash.clone(), import.clone())
        .await?;
    let stale = b_store
        .publish_cluster_change(b, hash.clone(), import)
        .await?;
    let deleted = a_store
        .publish_cluster_change(
            a,
            hash.clone(),
            syncstr_headless::cluster_changes::Action::Delete,
        )
        .await?;
    assert!(
        b_store
            .apply_cluster_changes(a.id().to_string(), vec![deleted.clone()])
            .await
            .is_err()
    );
    assert_eq!(b_store.cluster_changes().await?.len(), 1);
    a_store
        .apply_cluster_changes(b.id().to_string(), vec![stale])
        .await?;
    for _ in 0..2 {
        b_store
            .apply_cluster_changes(a.id().to_string(), vec![first.clone(), deleted.clone()])
            .await?;
    }
    for (_, store) in &nodes {
        let objects = store.cluster_object_states().await?;
        assert_eq!(objects.len(), 1);
        assert_eq!(objects[0].heads, vec![deleted.clone()]);
        assert_eq!(store.cluster_changes().await?.len(), 3);
    }
    drop(nodes);
    let reopened = syncstr_headless::store::Store::open(&root.path().join("b/data"))?;
    assert_eq!(
        reopened.cluster_object_states().await?[0].heads,
        vec![deleted]
    );
    Ok(())
}

#[tokio::test]
async fn explicit_restoration_conflicts_with_concurrent_deletion_until_user_selection()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let nodes = crate::hosts(root.path()).await?;
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    let (hash, import) = crate::fixture();
    let first = a_store
        .publish_cluster_change(a, hash.clone(), import.clone())
        .await?;
    b_store
        .apply_cluster_changes(a.id().to_string(), vec![first])
        .await?;
    let deleted = a_store
        .publish_cluster_change(
            a,
            hash.clone(),
            syncstr_headless::cluster_changes::Action::Delete,
        )
        .await?;
    let syncstr_headless::cluster_changes::Action::Import {
        entry,
        organization,
    } = import
    else {
        unreachable!()
    };
    let restored = b_store
        .publish_cluster_change(
            b,
            hash.clone(),
            syncstr_headless::cluster_changes::Action::Restore {
                entry,
                organization,
            },
        )
        .await?;
    a_store
        .apply_cluster_changes(b.id().to_string(), vec![restored.clone()])
        .await?;
    b_store
        .apply_cluster_changes(a.id().to_string(), vec![deleted])
        .await?;
    assert!(a_store.cluster_object_states().await?[0].conflicted());
    assert!(b_store.cluster_object_states().await?[0].conflicted());
    let chosen = a_store
        .publish_cluster_change(
            a,
            hash,
            syncstr_headless::cluster_changes::Action::Resolve {
                selected: restored.id,
            },
        )
        .await?;
    b_store
        .apply_cluster_changes(a.id().to_string(), vec![chosen.clone()])
        .await?;
    assert_eq!(
        b_store.cluster_object_states().await?[0].heads,
        vec![chosen]
    );
    assert_eq!(b_store.cluster_changes().await?.len(), 4);
    Ok(())
}

#[tokio::test]
async fn unauthenticated_or_tampered_records_never_enter_history() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let nodes = crate::hosts(root.path()).await?;
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    let (hash, import) = crate::fixture();
    let first = a_store.publish_cluster_change(a, hash, import).await?;
    assert!(
        b_store
            .apply_cluster_changes(
                iroh::SecretKey::generate().public().to_string(),
                vec![first.clone()]
            )
            .await
            .is_err()
    );
    let mut forged = first.clone();
    forged.action = syncstr_headless::cluster_changes::Action::Delete;
    assert!(
        b_store
            .apply_cluster_changes(a.id().to_string(), vec![forged])
            .await
            .is_err()
    );
    assert!(b_store.cluster_changes().await?.is_empty());
    b_store.revoke_cluster_member(b, a.id().to_string()).await?;
    assert!(
        b_store
            .apply_cluster_changes(a.id().to_string(), vec![first])
            .await
            .is_err()
    );
    assert!(b_store.cluster_changes().await?.is_empty());
    Ok(())
}
