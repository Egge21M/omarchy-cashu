# Handoff: Slice 5 — Prepare, confirm, and copy a Send

## Objective

Implement [GitHub issue #5 — Prepare, confirm, and copy a Send](https://github.com/Egge21M/omarchy-cashu/issues/5) in `/home/egge/projects/omarchy-cashu`.

The GitHub issue is the authoritative specification and acceptance checklist. Follow it directly; do not create a competing local specification or duplicate its contract in project documentation.

## Current state

- Branch: `master`
- HEAD: `af1b0f4` (`feat: resume interrupted receives`)
- Worktree: clean when this handoff was created
- Completed Slices 1, 2, 3, 4, 13, 15, and 6 are present on local `master`.
- Issue #5 is open, labelled `ready-for-agent`, and has no open blockers. Its dependencies #6 and #13 are closed.
- Create a new `feat/` branch from `af1b0f4` before editing.
- No push or other publication was performed while creating this handoff.

## Read first

- `/home/egge/projects/omarchy-cashu/AGENTS.md`
- [GitHub issue #5](https://github.com/Egge21M/omarchy-cashu/issues/5), including its live dependency state
- `/home/egge/projects/omarchy-cashu/CONTEXT.md`
- `/home/egge/projects/omarchy-cashu/docs/adr/0003-use-http-json-and-sse-for-shell-communication.md`
- `/home/egge/projects/omarchy-cashu/docs/reference/cocod-network-interface-v1.md`
- `/home/egge/projects/omarchy-cashu/README.md`
- Commit `af1b0f4`, which provides the reusable Operation discovery, lookup, refresh, reconnect, and invalidation foundation established by Slice 6

## Working boundaries

Extend the existing Shell Adapter seam in `/home/egge/projects/omarchy-cashu/Service.qml`. The current client already discovers and projects canonical Send Operation collections. Replace the Send placeholder in `/home/egge/projects/omarchy-cashu/Panel.qml` with the issue-defined flow, using the deterministic fixture and runtime harnesses already present in:

- `/home/egge/projects/omarchy-cashu/scripts/mock-cocod.py`
- `/home/egge/projects/omarchy-cashu/tests/contract.sh`
- `/home/egge/projects/omarchy-cashu/tests/runtime.sh`
- `/home/egge/projects/omarchy-cashu/tests/runtime-shell.qml`

Preserve the established custody boundary: cocod owns proof selection, reservations, fees, Send Max, execution, outgoing token generation, and authoritative Operation state. QML owns presentation and explicit user intent. Reuse Slice 6's canonical resource machinery rather than introducing a client-authoritative transfer state machine.

Encoded token data must remain confined to the immediate authenticated execution response and the explicit copy interaction specified by #5. It must not enter generic adapter state, Operation collections, diagnostics, SSE, logs, or persistence.

Keep scope strictly to #5. Do not implement Pending Send recovery or Reclaim (#7), real-daemon integration (#8/#11), QR output, Lightning, non-sat units, or new protocol resources.

## Verification and closeout

- Convert the issue's acceptance criteria into failing contract and supported-runtime coverage before implementation.
- Run `git diff --check` and the complete `/home/egge/projects/omarchy-cashu/scripts/smoke.sh` suite. Loopback and Wayland clipboard checks may require sandbox approval and a supported Omarchy session.
- Audit the final diff against every checkbox in issue #5, especially decimal-string preservation, daemon-only calculations, explicit clipboard behavior, and redaction.
- Report exact commands and results, including any environment-limited check.
- Do not stage, commit, push, close the issue, or create a PR without the user's explicit authorization for each action.

## Suggested skills

- `$tdd` — drive Send Max, preparation, reservation, cancellation, execution, copying, stale data, structured errors, and redaction through tests first.
- `$codebase-design` — deepen the existing Operation adapter instead of leaking transport and custody concerns into presentation QML.
- `$diagnosing-bugs` — invoke if QML transitions, SSE invalidation ordering, decimal handling, or clipboard tests become nondeterministic.
- `$github` — read issue #5 and its dependencies; perform GitHub writes only when authorized.

## Continuation checkpoint — 2026-08-21

- Active branch: `feat/prepare-confirm-copy-send`; HEAD remains `af1b0f4`.
- The Slice 5 implementation is present as uncommitted work in `Panel.qml`, `SendFlow.qml`, `Service.qml`, `README.md`, `scripts/check.sh`, `scripts/mock-cocod.py`, `tests/contract.sh`, `tests/runtime-shell.qml`, and `tests/runtime.sh`.
- Do not stage, commit, push, close the issue, or create a PR without explicit authorization.
- A complete `./scripts/smoke.sh` run passed before the latest review fixes. It covered contract checks, runtime composition, Send Max, prepare/review/cancel, execution and explicit copy, redaction, ambiguous creation recovery, canonical refresh overlap, rotation, and decimal strings.
- Repeated `codex review --uncommitted` passes found and drove fixes for stale Max application, mint revalidation, post-execute reconciliation, connection rotation, ambiguous committed creation, unavailable execution, stale Send collection responses, authoritative daemon Max, and deferred rotation priority.
- Later accepted review findings were: stale incremental balance fetches overwriting reconciled balances; Send/balance invalidations being dropped during Send mutations; inability to dismiss a reviewed Send during a full canonical refresh; and cached Max bypassing current canonical Mint trust.
- Regression coverage for those cases was added first and failed as expected. `Service.qml` now aborts superseded incremental Send/balance fetches, coalesces and replays queued invalidations, defers reviewed-Send cancellation until a full refresh finishes, and requires current trusted-Mint membership even when cached daemon Max authorizes a stale balance. `SendFlow.qml` independently clears a Max-backed selection when canonical trust is revoked.
- Post-fix `./tests/runtime.sh` and the complete `./scripts/smoke.sh` both pass. The final `codex review --uncommitted` reported no accepted/actionable findings or advisories.
- No runtime/mock process was left behind after the interruption.

### Closeout state

Implementation and local closeout are complete. The worktree remains deliberately uncommitted and unpublished pending explicit user authorization.
