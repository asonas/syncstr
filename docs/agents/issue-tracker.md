# Issue tracker: Linear

Issues and specs for this repo live in the **Syncstr** project in Linear. Use the connected Linear tools for issue operations.

## Scope

Resolve the Syncstr project and its owning team through Linear before creating issues. Set both the project and team when creating an issue, and scope issue searches to this project. If the project name is ambiguous, ask which project to use.

## Conventions

- **Create**: create a Linear issue in the Syncstr project with a title and description.
- **Read**: fetch the issue description, comments, labels, and relations before acting.
- **List**: filter by the Syncstr project and the relevant statuses or labels; follow pagination when needed.
- **Comment**: add findings and verification results to the Linear issue.
- **Labels**: use the mapping in [triage-labels.md](triage-labels.md). Preserve unrelated labels when adding or removing a triage label.
- **Resolve**: look up the team's available statuses and select the appropriate completed or canceled status. Do not assume a status name.
- **References**: use Linear issue identifiers or URLs. Existing GitHub issue references remain GitHub references.

## When a skill says "publish to the issue tracker"

Create a Linear issue in the Syncstr project.

## When a skill says "fetch the relevant ticket"

Read the Linear issue, including its comments and relations.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets, all in the Syncstr project.

- **Map**: an issue labeled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: a native sub-issue of the map, labeled `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Keep ticket order explicit in the map body.
- **Blocking**: use native blocking relations. Check each blocker's current state before treating a ticket as unblocked; cancellation does not by itself prove a prerequisite was satisfied.
- **Frontier query**: list the map's unfinished children, exclude assigned tickets and tickets with unresolved blockers, then choose the first eligible ticket in map order.
- **Claim**: assign the ticket to the driving developer as the session's first write.
- **Resolve**: comment with the answer and verification results, update the ticket's status, and append a summary and ticket link to the map's Decisions-so-far.

## GitHub

GitHub remains the source repository and pull request host. Use `gh` for GitHub operations. Existing GitHub issues remain historical references; migrating them requires a separate request. Do not create new GitHub issues for this workflow.

**PRs as a request surface: no.**
