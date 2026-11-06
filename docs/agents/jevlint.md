# Pull request quality review

[Jevlint review](../../.github/workflows/jevlint.yml) runs when a pull request is
opened, updated, reopened, or edited. Read its report on the Actions run's Summary
page. It does not post PR comments or modify source files.

For repository branches, `jevlint pr --intent --ignore-pins` uses TypeSafe AI's
Jev model to compare changed files with their merge-base versions and report new
or worse findings. Intent evaluation compares the PR title and body with the diff
and the root `AGENTS.md` from the merge base. Linked documents are not followed.
Fork and Dependabot PRs receive AST-only reviews without intent evaluation.

The check is advisory, including setup and service failures. Findings do not
prevent merging. The summary includes the review step outcome and diagnostics;
check warnings, skipped files, and truncation before relying on a result. A
successful step alone does not prove every model request succeeded: jevlint can
report provider failures as warnings.

## API key

Create the repository Actions secret `TYPESAFE_AI_API_KEY` with a Jev API key.
The workflow enables environment-key access with `jevlint auth env on`. A missing
key on a repository branch is reported as a failed review step, rather than
silently substituting an AST-only review. Never put the key in `jevlint.toml`.

Model review sends the contents of changed files before and after the change to
TypeSafe AI, within jevlint's size limits. Intent evaluation also sends the PR
title, body, diff, and base instructions. The tool's file exclusions do not detect
secrets embedded inside source code.

## Configuration and cache

[jevlint.toml](../../jevlint.toml) selects `readable-code` and `software-design`.
The workflow checks out the PR's base commit so changes to the configuration and
presets only take effect after integration into the base branch. The initial
installation PR therefore uses jevlint's defaults until its config is merged.

The CLI is pinned to `0.2.1`. The model initially uses `jev-latest`; replace it
with a version available to the account when reproducible model comparisons are
needed. A moving model alias can reuse answers produced by an older version.
After a model upgrade, bump the `jevlint-v1` cache prefix in the workflow to clear
those answers. Do not cache the credentials directory. Local re-runs can use
`--no-cache` when fresh answers are needed.

The shared Actions cache stores model answers keyed by content and questions to
reduce repeat requests. A new cache entry is saved for each run and attempt, so
editing only the PR description can preserve the new intent answer too.

Swift and Kotlin use approximate static metrics; Rust and TypeScript have
grammar-based analysis on the hosted Linux runner. Use the findings to guide
human review, alongside the existing build and regression checks. Small model
score changes are not reliable evidence of a quality regression.

## Local review

Install Node.js `24.22.1` or another version supported by the pinned package,
then use an authenticated GitHub CLI:

```sh
npm install --global @indxjp/jevlint@0.2.1
jevlint auth set typesafe
jevlint pr 123 --intent --ignore-pins
```

The local command uses the configuration in the current checkout. To review
without a model key, use `jevlint pr 123 --ast-only --ignore-pins`.

## References

- [Upstream CI guide](https://github.com/INDXDev/jevlint/blob/main/docs/ci.md)
- [Provider configuration](https://github.com/INDXDev/jevlint/blob/main/docs/providers.md)
- [CLI and review limitations](https://github.com/INDXDev/jevlint/blob/main/docs/cli.md)
- [Cache behavior](https://github.com/INDXDev/jevlint/blob/main/docs/caching.md)
