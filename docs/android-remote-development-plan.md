# Remote Android development

Status: Linux remote build, local physical-device installation, automated playback and update retention verified. Remote Codex skill discovery verified. Human audio/radios-disabled acceptance and Play distribution are tracked separately below.

## Purpose

Move implementation and compilation to an SSH-accessible machine while keeping physical Android verification close to the developer. A future agent should be able to resume this work, identify the next unverified step, and reproduce the approved workflow without inferring success from a build alone.

## Agreed baseline

- Use Herdr to work with a remote development environment.
- Start by evaluating the Linux NAS as the build machine. Retain a WSL workstation as an alternative based on measured resource availability and build results.
- Build an ARM64 APK remotely, retrieve it to the local Mac, and verify it on a physical Android device through ADB.
- Use direct APK installation for frequent iterations. Add Google Play internal testing for selected builds as a subsequent distribution step.
- Add a remote emulator only when it serves a concrete verification need.
- Maintain a Syncstr-specific skill that refers to the project documentation and verified scripts. Reuse the existing Herdr skill for general terminal operations.
- Install a separate development application ID alongside the everyday app, with its own enrollment into a disposable test cluster.
- After initial setup, an explicitly requested development iteration includes remote build, artifact retrieval, installation on the configured development device, launch, logs, and screenshots. Human audio confirmation remains a separate observation. Play publication requires a separate invocation.
- Use a dedicated remote worktree as the authoritative working copy during an iteration. Hand code between machines through Git; keep the Mac's copy out of concurrent editing on that branch. Main integration and push follow the scope of the specific request.
- Use one stable development-only signing key outside the repository, provisioned only to authorized build machines. Preserve it when changing build machines so updates retain the development app's identity and saved data.
- Keep the [skill source](../.agents/skills/syncstr-android-dev/SKILL.md) in this repository, versioned with its instructions and scripts. Maintain one authored source for all participating agents.

## Current implementation constraints

Implemented on repository baseline `5588b72`:

- [The native build script](../apps/android/build-native.sh) selects the macOS or x86_64 Linux NDK toolchain. Linux compilation and packaging passed. Native Windows support has a separate verification record; WSL execution has not been verified.
- [The app build](../apps/android/app/build.gradle.kts) packages `arm64-v8a` only. An x86_64 emulator requires an appropriate native-library build and packaging configuration.
- [The Android guide](../apps/android/README.md) specifies the current toolchain. The integrated main branch includes a Gradle wrapper pinned to 8.13.
- [The existing development handoff](android-ui-development-handoff.md) records identity preservation, signing compatibility, and physical-device checks. Reuse these contracts rather than duplicating them.

## Setup and acceptance checklist

### 1. Verify the remote build environment

Inspect CPU architecture, available memory and disk, installed toolchains, SSH/Herdr connectivity, and repository state. Measure a build before selecting the primary machine. Keep the development checkout and test data separate from the running music service. Record the selected host and physical device in local configuration; keep personal hostnames, device IDs, and private paths out of published documentation.

- [x] Record the candidate machine's available resources and missing prerequisites.
- [x] Establish the remote checkout/worktree and its Git handoff path without overwriting existing work.
- [x] Identify the local device through ADB; check its ABI and debugging authorization.

Deliverable: an explicit build-machine candidate, working-copy ownership, and a selected development device. Confirm the primary machine after the measured build in step 2.

### 2. Produce a reproducible Linux build

Adapt NDK host-toolchain selection for Linux, install or select the documented dependencies, and build the Rust JNI library and Android APK. Run relevant native checks and Android Lint. Record the source revision, working-tree changes if any, artifact hash, application ID, version, ABI, and signing certificate identity with the artifact. Keep machine-specific records outside Git.

- [x] Verify Linux native compilation and Android packaging using the repository's pinned dependencies.
- [x] Add a distinct development application ID and visible development label; verify the everyday application ID is unchanged.
- [x] Configure a stable development-only signing key outside Git. Record its certificate fingerprint and a private recovery reference. Establish a protected backup using the owner's existing credential/backup mechanism before relying on the key for retained development data.
- [x] Build twice and verify that both APKs have the intended development identity and the same signing certificate.
- [x] Record build duration and resource impact, then confirm the machine choice.

Deliverable: an identifiable APK and a verified build procedure.

### 3. Close the physical-device feedback loop

Retrieve the APK, verify its identity, select the intended device explicitly, and apply the agreed app-data and signing policy before installation. Capture launch results, logs, and screenshots. Verify enrollment, catalog refresh, selective download, and offline restoration against a disposable test cluster. Record audible playback as a separate human observation.

- [x] Check that the local APK hash matches the remote artifact and inspect its application ID and signing certificate before installation.
- [x] Install the development app alongside the everyday app and verify both remain present.
- [x] Launch the intended development activity, capture its screen, and inspect its process logs for startup failures.
- [x] Verify test-cluster discovery/enrollment, catalog-only refresh, selected download, saved playback and update retention using real-device instrumentation.
- [ ] Confirm audible playback after an app restart with device radios disabled. Broader UI acceptance remains scoped to future UI changes; see the [device flows](android-ui-development-handoff.md#verification-during-ui-development).
- [x] Install a second development build over the first and verify retained enrollment and saved audio. A signature mismatch is a configuration failure, not a reason to uninstall the app.

Deliverable: an approved repeatable workflow from source revision to device evidence.

### 4. Verify and refine the repository skill

The entry point is [syncstr-android-dev](../.agents/skills/syncstr-android-dev/SKILL.md). It covers first-time setup and subsequent development iterations. Maintain executable project commands in repository scripts as they become verified; keep the skill focused on choosing and completing the appropriate workflow.

- [x] Author the repository-local skill and link it from the documentation map.
- [x] Confirm the actual remote agent can discover and read the skill from the intended checkout. For agents using another discovery directory, verify an adapter to this source rather than maintaining an independent copy.
- [x] Run one complete development iteration and refine the skill against observed failures.
- [x] Verify the helper command or commands added during implementation, including failure reporting when no configured device is available.

Deliverable: a small skill grounded in a successful end-to-end run, with a documented invocation boundary.

### 5. Add internal-test distribution

Define release signing, application identity, version increments, artifact provenance, and publication authorization before configuring Google Play internal testing. Verify installation and updates on the tester device independently from upload success.

- [ ] Design the Play signing and application-ID relationship when distribution work starts; the development key is not automatically the Play signing identity.
- [ ] Configure internal testing and verify a tester-device update after an explicitly requested publication.

Deliverable: a repeatable distribution path for selected builds.

## Setup verification record

The selected Linux build machine has an x86_64 CPU with 20 logical cores and
approximately 32 GB RAM. About 11 GB RAM and 68 GB disk space were available
before setup. The build used four Cargo jobs and two Gradle workers at reduced
CPU priority; roughly 11 GB RAM remained available during the initial run.

Native ARM64 compilation took about 96 seconds. Initial Lint took about 91
seconds while overlapping native compilation; APK packaging took about 20
seconds afterward. The complete repeat build helper took about 29 seconds
(including a partial native rebuild). These are individual observations with
existing tool caches, not a cold-build benchmark. They support using the Linux
machine as the primary build host; no WSL comparison has been measured.

The development certificate was checked across two builds. A forced Gradle
rebuild produced the same APK hash, which matched after retrieval. The key is
mode 0600 on the build host with a matching protected copy on the local
controller. Private records retain its certificate and recovery location.

On an Android 16 ARM64 device, the development and everyday packages coexist.
The isolated fixture host was discovered through NSD. Instrumentation enrolled,
refreshed without automatically downloading audio, downloaded one verified MP3,
and observed advancing MediaPlayer playback. After an APK replacement, hashes
of the encrypted identity preferences, library database and saved original were
unchanged. With the fixture host stopped, a separate instrumentation process
restored the catalog and played saved audio. This does not establish that the
device radios were disabled or that a person heard the sound.

At the setup baseline, the initial unenrolled screen displayed the raw error “Query returned
no rows”; the enrolled screen displayed the fixture track. Subsequent main-branch UI improvements supersede this screen; see the
[repair record](validation/windows-android-review-repairs.md).

The remote Codex `skills/list` response reported the repository skill enabled
with repository scope and no discovery errors. Other agents' discovery was not
tested. The [build helper](../apps/android/build-development.sh) passed a full
run and rejected a missing key before compilation. Explicit ADB selection
rejected a nonexistent device without choosing another one. No store upload,
main integration or push was performed as part of this setup.

## Decision rationale

The remote-build choice leads to one remote working copy and explicit Git handoff, avoiding conflicting edits across machines. The separate development-app choice leads to a stable development signing identity, enabling repeated updates without discarding enrollment or saved audio. The project-specific skill choice leads to repository-local authorship, keeping the instructions and implementation at the same revision. These six choices were accepted during the design interview.

Shared skills already have a separate authorship and APM distribution path. This project-local skill follows the repository instead; remote discovery is an acceptance check, not an assumed benefit of cloning. Generalize the skill only when another application demonstrates a concrete shared need.

Machine capacity, agent discovery, device availability, and tool versions are investigation tasks. Private signing-key backup and provisioning details are settled against the available credential-storage mechanism during setup. Play release details belong to step 5.

## Evidence boundaries

A successful build proves artifact generation. Installation proves that the selected device accepted that artifact. Launch, screen behavior, network transfer, offline playback, and audible output require their own observations. SSH connectivity does not establish emulator acceleration or Android device access.

## Reference material

- [Herdr machine connections](https://herdr.dev/docs/connecting-machines/)
- [Android Debug Bridge](https://developer.android.com/tools/adb)
- [Google Play internal testing](https://support.google.com/googleplay/android-developer/answer/9845334)
