# Review Standards

## UI Changes

Compare the diff with [DESIGN.md](DESIGN.md). Keep design criteria there rather than duplicating the same rules here.

1. Check whether headings, explanations, and status labels repeat selected navigation or visible state. Preserve necessary failure reasons, operation results, and accessibility state announcements.
2. Open the changed screen in the target build and inspect the relevant states. For search, check normal, focused, typing, and cleared states. For selected rows, check selection styling and clicks on padding. For layout, check normal and narrow windows.
3. For interaction changes, verify the [cross-platform procedure](README.md#changes-to-app-interactions): account for both macOS and iOS entry points, shared-code effects, and the expected state transitions. Check that each platform has a change, a reason it needs no change, or an explicit verification gap. Do not add tests where existing checks suffice. Searching source strings alone does not verify the actual screen.
4. Record the target build, interactions and display states checked, and anything unverified. Report build success, visual verification, main integration, push, and distribution separately.

For checks requiring screenshots or production audio, respect actions the user has reserved for themselves. Never report an unperformed check as successful.

## macOS Verification Target

Follow the [macOS launch procedure](apps/macos/README.md#build-and-run). Before checking the screen, verify that the executable path matches the target app and exactly one process is running.

Manual builds and Xcode/TestFlight builds use different bundle IDs and storage containers. Inspect the target app's Info.plist and executable path instead of identifying it only by name. Before replacing an installed app with another distribution variant, confirm the target and the effect on saved data. Quit an app before removing its validation worktree.

If the launch target cannot be verified, report visual verification as incomplete. Do not judge old screens as results of the latest code.
