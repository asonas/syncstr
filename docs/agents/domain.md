# Domain docs

## Exploring the implementation

Use the [README map](../../README.md#code-and-documentation-map) to find the relevant source and app guide. The current playback path uses Navidrome/OpenSubsonic; the synchronization server in the initial design has a different scope.

## Finding decisions

- [Design specification](../design-spec.md): UI principles and the long-term service specification.
- [Design decisions](../decisions.md): initial rationale and unresolved questions. Check applicability against [deferred work](../../README.md#long-term-design-and-deferred-work).
- [DESIGN.md](../../DESIGN.md): UI and icon appearance.
- [GitHub issues](https://github.com/asonas/syncstr/issues): subsequent scope changes and verification results. Follow successor issues when consulting an older decision.

Use the terminology in the relevant document and source code. If a proposed change contradicts a decision, identify its decision ID or issue and explain the conflict.

If `CONTEXT.md` or `docs/adr/` is added later, read the vocabulary or decisions relevant to the task. Otherwise, use the existing references above; do not create empty documents to satisfy a template.
