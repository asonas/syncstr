#![cfg(feature = "p2p")]

#[tokio::test]
async fn encrypted_enrollment_pins_the_host_and_binds_the_transport_identity() -> anyhow::Result<()>
{
    let root = tempfile::tempdir()?;
    let mut nodes = Vec::new();
    for name in ["host", "phone"] {
        let key = root.path().join(name).join("identity");
        syncstr_headless::peer::Identity::initialize(&key)?;
        nodes.push((
            std::sync::Arc::new(syncstr_headless::peer::Identity::open(&key)?),
            syncstr_headless::store::Store::open(&root.path().join(name).join("data"))?,
        ));
    }
    let (host, store) = &nodes[0];
    let (phone, phone_store) = &nodes[1];
    store.create_cluster(host.id().to_string()).await?;
    let now = syncstr_headless::rendezvous::now()? / 1000;
    let mut invite = store
        .create_cluster_invitation(host, false, now, 600)
        .await?;
    let (server, _server_lock) = host.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let (client, _client_lock) = phone.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let address = server.addr();
    let task = tokio::spawn(syncstr_headless::cluster_net::serve(
        host.clone(),
        server.clone(),
        store.clone(),
    ));
    let wrong = iroh::EndpointAddr::new(iroh::SecretKey::generate().public());
    assert!(
        syncstr_headless::cluster_net::enroll(phone, &client, wrong, &invite, phone_store)
            .await
            .is_err()
    );
    let secret = std::mem::replace(&mut invite.secret, "0".repeat(64));
    assert!(
        syncstr_headless::cluster_net::enroll(
            phone,
            &client,
            address.clone(),
            &invite,
            phone_store
        )
        .await
        .is_err()
    );
    assert!(phone_store.cluster_inventory().await?.cluster.is_none());
    invite.secret = secret;
    syncstr_headless::cluster_net::enroll(phone, &client, address.clone(), &invite, phone_store)
        .await?;
    let cluster = phone_store.cluster_inventory().await?.cluster.unwrap();
    assert_eq!(cluster.id, invite.cluster);
    assert_eq!(cluster.member_id, phone.id().to_string());
    assert!(!host.is_paired(phone.id()));
    assert!(
        syncstr_headless::cluster_net::enroll(phone, &client, address, &invite, phone_store)
            .await
            .is_err()
    );
    client.close().await;
    server.close().await;
    task.await?;
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
        let key = root.join(name).join("identity");
        syncstr_headless::peer::Identity::initialize(&key)?;
        nodes.push((
            syncstr_headless::peer::Identity::open(&key)?,
            syncstr_headless::store::Store::open(&root.join(name).join("data"))?,
        ));
    }
    let (a, store) = &nodes[0];
    store.create_cluster(a.id().to_string()).await?;
    let invitation = store.create_cluster_invitation(a, true, 1000, 600).await?;
    let grant = store
        .redeem_cluster_invitation(a, &invitation.secret, nodes[1].0.id().to_string(), 1100)
        .await?;
    nodes[1]
        .1
        .join_cluster(
            &nodes[1].0,
            a.id(),
            grant.id,
            store.cluster_membership_proof().await?,
        )
        .await?;
    Ok(nodes)
}

#[tokio::test]
async fn revocation_preserves_known_grants_but_rejects_backdated_authority() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let nodes = crate::hosts(root.path()).await?;
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    let b_grant = b_store
        .cluster_membership_proof()
        .await?
        .grants
        .into_iter()
        .find(|grant| grant.member == b.id().to_string())
        .unwrap();
    b_store.revoke_cluster_member(b, a.id().to_string()).await?;
    let revoked = b_store.cluster_membership_proof().await?;
    assert!(revoked.verify(&b_grant.id).is_ok());
    let root_grant = revoked
        .grants
        .iter()
        .find(|grant| grant.authority.is_none())
        .unwrap();
    assert!(revoked.verify(&root_grant.id).is_err());
    let mut reused_id = b_grant.clone();
    reused_id.member = iroh::SecretKey::generate().public().to_string();
    let payload = serde_json::json!([
        reused_id.version,
        reused_id.cluster,
        reused_id.issuer,
        reused_id.member,
        reused_id.host,
        reused_id.authority
    ]);
    reused_id.signature =
        hex::encode(a.sign(format!("syncstr-enrollment-grant-v1\n{payload}").as_bytes()));
    assert!(
        reused_id.verify_signature().is_err(),
        "a compromised issuer cannot rewrite a content identity that a revocation already observed"
    );
    let invitation = a_store
        .create_cluster_invitation(a, true, 1200, 600)
        .await?;
    let forged = a_store
        .redeem_cluster_invitation(
            a,
            &invitation.secret,
            iroh::SecretKey::generate().public().to_string(),
            1300,
        )
        .await?;
    b_store
        .merge_cluster_membership(a_store.cluster_membership_proof().await?)
        .await?;
    assert!(
        b_store
            .cluster_membership_proof()
            .await?
            .verify(&forged.id)
            .is_err()
    );
    a_store.merge_cluster_membership(revoked).await?;
    assert!(
        a_store
            .create_cluster_invitation(a, true, 1400, 600)
            .await
            .is_err()
    );
    assert!(
        b_store
            .create_cluster_invitation(b, false, 1400, 600)
            .await
            .is_ok()
    );
    let proof = b_store.cluster_membership_proof().await?;
    b_store.merge_cluster_membership(proof.clone()).await?;
    assert!(
        b_store
            .cluster_membership_proof()
            .await?
            .verify(&b_grant.id)
            .is_ok()
    );
    Ok(())
}

#[tokio::test]
async fn concurrent_revocations_preserve_conflict_and_never_choose_a_clock_winner()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let nodes = crate::hosts(root.path()).await?;
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    a_store.revoke_cluster_member(a, b.id().to_string()).await?;
    b_store.revoke_cluster_member(b, a.id().to_string()).await?;
    let left = a_store.cluster_membership_proof().await?;
    let right = b_store.cluster_membership_proof().await?;
    a_store.merge_cluster_membership(right).await?;
    b_store.merge_cluster_membership(left).await?;
    let expected = std::collections::BTreeSet::from([a.id().to_string(), b.id().to_string()]);
    for (_, store) in &nodes {
        let mut proof = store.cluster_membership_proof().await?;
        assert_eq!(proof.membership_conflicts()?, expected);
        for grant in &proof.grants {
            assert!(proof.verify(&grant.id).is_err());
        }
        proof.revocations.reverse();
        assert_eq!(proof.membership_conflicts()?, expected);
        assert_eq!(proof.revocations.len(), 2);
    }
    Ok(())
}

#[tokio::test]
async fn another_host_verifies_enrollment_without_sharing_private_keys() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let mut nodes = Vec::new();
    for name in ["a", "b", "phone"] {
        let key = root.path().join(name).join("identity");
        syncstr_headless::peer::Identity::initialize(&key)?;
        nodes.push((
            syncstr_headless::peer::Identity::open(&key)?,
            syncstr_headless::store::Store::open(&root.path().join(name).join("data"))?,
        ));
    }
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    let (phone, phone_store) = &nodes[2];
    let cluster = a_store.create_cluster(a.id().to_string()).await?;
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
    assert_eq!(
        b_store.cluster_inventory().await?.cluster.unwrap().id,
        cluster.id
    );
    let invitation = b_store
        .create_cluster_invitation(b, false, 1200, 600)
        .await?;
    let grant = b_store
        .redeem_cluster_invitation(b, &invitation.secret, phone.id().to_string(), 1300)
        .await?;
    let proof = b_store.cluster_membership_proof().await?;
    assert_eq!(proof.root, a.id().to_string());
    assert_eq!(proof.verify(&grant.id)?.member, phone.id().to_string());
    let mut forged = proof.clone();
    forged.root = iroh::SecretKey::generate().public().to_string();
    assert!(forged.verify(&grant.id).is_err());
    assert!(
        phone_store
            .join_cluster(phone, a.id(), grant.id.clone(), proof.clone())
            .await
            .is_err()
    );
    phone_store
        .join_cluster(phone, b.id(), grant.id, proof)
        .await?;
    assert!(
        phone_store
            .create_cluster_invitation(phone, true, 1400, 600)
            .await
            .is_err()
    );
    assert_ne!(a.id(), b.id());
    assert_ne!(a.id(), phone.id());
    Ok(())
}

#[tokio::test]
async fn invitations_expire_bind_one_key_and_survive_restart() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    syncstr_headless::peer::Identity::initialize(&root.path().join("identity"))?;
    let host = syncstr_headless::peer::Identity::open(&root.path().join("identity"))?;
    store.create_cluster(host.id().to_string()).await?;
    let invite = store
        .create_cluster_invitation(&host, true, 1000, 600)
        .await?;
    assert_eq!(invite.host, host.id().to_string());
    assert_eq!(invite.expires, 1600);
    drop(store);
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    let client = iroh::SecretKey::generate().public();
    assert!(
        store
            .redeem_cluster_invitation(&host, &invite.secret, client.to_string(), 1600)
            .await
            .is_err()
    );
    assert!(
        store
            .redeem_cluster_invitation(&host, "wrong", client.to_string(), 1100)
            .await
            .is_err()
    );
    let grant = store
        .redeem_cluster_invitation(&host, &invite.secret, client.to_string(), 1100)
        .await?;
    assert_eq!(grant.member, client.to_string());
    assert!(grant.host);
    grant.verify_signature()?;
    let mut forged = grant.clone();
    forged.member = iroh::SecretKey::generate().public().to_string();
    assert!(forged.verify_signature().is_err());
    assert!(
        store
            .redeem_cluster_invitation(
                &host,
                &invite.secret,
                iroh::SecretKey::generate().public().to_string(),
                1101
            )
            .await
            .is_err()
    );
    assert!(
        store
            .redeem_cluster_invitation(&host, &invite.secret, client.to_string(), 1101)
            .await
            .is_err()
    );
    Ok(())
}

#[tokio::test]
async fn concurrent_redemption_has_one_winner_and_failed_commit_retains_invitation()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    syncstr_headless::peer::Identity::initialize(&root.path().join("identity"))?;
    let host = syncstr_headless::peer::Identity::open(&root.path().join("identity"))?;
    let data = root.path().join("data");
    let store = syncstr_headless::store::Store::open(&data)?;
    store.create_cluster(host.id().to_string()).await?;
    let invite = store
        .create_cluster_invitation(&host, false, 1000, 600)
        .await?;
    let sql = rusqlite::Connection::open(data.join("node.sqlite"))?;
    sql.execute_batch("CREATE TRIGGER reject_grant BEFORE INSERT ON cluster_enrollment_grants BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")?;
    let first = iroh::SecretKey::generate().public().to_string();
    let second = iroh::SecretKey::generate().public().to_string();
    assert!(
        store
            .redeem_cluster_invitation(&host, &invite.secret, first.clone(), 1100)
            .await
            .is_err()
    );
    sql.execute_batch("DROP TRIGGER reject_grant")?;
    let (a, b) = tokio::join!(
        store.redeem_cluster_invitation(&host, &invite.secret, first, 1101),
        store.redeem_cluster_invitation(&host, &invite.secret, second, 1101),
    );
    assert_ne!(a.is_ok(), b.is_ok());
    let grant = a.or(b)?;
    assert!(!grant.host);
    assert!(
        store
            .redeem_cluster_invitation(&host, &invite.secret, grant.member.clone(), 1102)
            .await
            .is_err()
    );
    assert_eq!(
        sql.query_row(
            "SELECT count(*) FROM cluster_enrollment_grants",
            [],
            |row| row.get::<_, i64>(0)
        )?,
        2
    );
    assert_eq!(
        sql.query_row(
            "SELECT count(*) FROM cluster_invitations WHERE digest = ?",
            [&invite.secret],
            |row| row.get::<_, i64>(0)
        )?,
        0,
        "the invitation secret must not be stored as plaintext"
    );
    Ok(())
}
