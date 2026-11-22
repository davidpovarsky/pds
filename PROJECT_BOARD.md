# Project Board

This is a living working-memory document for this repository.
It is intentionally lightweight. Humans and coding agents should update it when useful discoveries, ideas, plans, optimizations, problems, or follow-up work arise during normal development.
Do not turn this into a duplicate issue tracker or a dump of temporary thoughts.

## Inbox

Quick captures that still need classification.

## Ideas & Opportunities

Potential improvements, features, optimizations, or architectural ideas.

## Discoveries & Tips

Useful technical discoveries, undocumented behavior, shortcuts, implementation tricks, platform behavior, or reusable knowledge discovered while working.

## Experiments / Investigations

Things worth testing or researching before deciding whether to implement them.

## Open Questions

Important unresolved questions or uncertainties.

## Planned / Todo

Concrete work that is worth doing but is not part of the current task.

- [ ] Reconcile `main` and `codex/torah-social-runtime-repair` in a separate upstream synchronization. On 2026-11-22, runtime head `a19c0bb` was 34 commits ahead and 4 behind `main`; `main` is not the maintained Torah deployment branch. Target operational Torah fixes at runtime until that reconciliation is reviewed.

Use Markdown checkboxes where useful:

- [ ] Example item

## Done

Completed items that are still useful to retain because they document an important decision, discovery, or implementation.

- [x] Recover public HTTPS and prevent installer reruns from deleting shared Caddy routes (2026-11-22, commit `4e502575`). The primary-interface bind avoids the Tailscale Serve collision; the helper preserves the PDS DID route and other sites. [Preservation CI](https://github.com/davidpovarsky/pds/actions/runs/44977714587) passed 12 regression tests and real Caddy validation. A live dry-run found no further change necessary, and the web/PDS/AppView endpoints returned HTTP 200. Operational commands and rollback behavior are in `torah-social/README.md`.

Example:

- [x] Example improvement
  - Implemented: YYYY-MM-DD
  - Commit/PR: ...
  - Notes: ...

## Archive

Older completed/superseded items that still have historical value.
