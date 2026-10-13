---
name: syncstr-android-dev
description: Set up or run Syncstr Android development with a remote build machine and local physical-device verification. Use for remote Android setup, implementation iterations, or diagnosis of that build-to-device workflow.
---

# Syncstr Android development

Read the [remote development plan](../../../docs/android-remote-development-plan.md) first. It owns the agreed topology, app/signing identity, setup checklist, and evidence requirements. Resolve its relative links from this checkout, including inside a worktree.

Loading this skill for advice or review does not request an execution run. For a requested development iteration, the normal outcome is the configured development app installed and launched on the selected physical device, with logs and a screenshot. Play publication is a separate task.

## Establish the current stage

Identify the requested work, local controller, remote build machine, authoritative remote worktree, and configured Android device from existing configuration. The local controller may keep private setup selections and artifact references in `$HOME/.local/state/syncstr/android-dev/context.json`; recheck those values against the live machines before using them. Check branch and working-tree state before moving code. Ask only for missing selections that affect the work; preserve previously accepted choices.

Compare the current build files and available tools with the plan's unchecked setup steps. The native script supports macOS and x86_64 Linux; debug builds use the separate development identity and require its stable keystore. Re-inspect the selected host and key provisioning before assuming they match the verified setup.

- For a setup request, work through the setup checklist and record verified commands in the project guide as each step passes.
- For a development request with missing prerequisites, complete the necessary setup within the requested scope before starting the iteration. If a prerequisite needs unavailable information or access, report the concrete dependency and complete independent work.
- For diagnosis, inspect the failing stage's evidence before changing code or environment.

## Run an iteration

1. **Implement remotely.** Work in the dedicated remote worktree, using the agreed Git handoff. If operating through Herdr, use the installed Herdr skill and live CLI help; specify the saved machine for remote commands. An already-running remote agent may own the worktree: coordinate that ownership before editing. Launch another agent only when authorized, following `herdr-agent-launch` in that case.
2. **Build and identify.** Follow the [Android build guide](../../../apps/android/README.md), using `sh apps/android/build-development.sh` with the documented SDK environment. Rebuild the JNI library when Rust or its Kotlin boundary changes. Run focused verification and record the source state and artifact metadata required by the plan. Avoid substituting stale native output from another revision or ABI.
3. **Retrieve and install.** Transfer the identified APK to the local controller and compare hashes. Verify its development application ID and certificate against the configured identity. Select the configured device explicitly. If the device is absent or ambiguous, retain the artifact and report that installation is pending; never select another device opportunistically or uninstall to bypass a signing mismatch.
4. **Observe.** Launch the development app, collect its logs and screenshot, and check the interactions affected by the change using the [device verification guide](../../../docs/android-ui-development-handoff.md#verification-during-ui-development). Enrollment and network checks use the disposable test cluster. Retain device identity and saved audio on ordinary updates. Check instrumentation result codes, not only ADB exit status. Record human audio confirmation and device radio state separately.
5. **Report.** Identify the source revision or dirty-source snapshot and artifact hash. Distinguish build, installation, launch, interaction checks, and audio observations. Keep personal device IDs, credentials, private paths, and raw operational logs out of published records. Integrate or push only within the requested delivery scope.

An unavailable device does not invalidate a successful build, and a successful build does not establish working playback. Stop the iteration when the requested behavior and relevant device checks are covered; report any remaining evidence gap precisely.
