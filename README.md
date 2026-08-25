# Cashu Wallet

Cashu Wallet is an Omarchy-native wallet interface for Cashu users. It provides a clean bar widget and panel while a dedicated `cocod` daemon owns wallet state, custody, and operations.

The Wallet Client is built as an Omarchy 4 Quickshell plugin with the ID `io.github.egge21m.omarchy-cashu`. It presents wallet state and requests operations without persisting wallet secrets or authoritative wallet data.

## Purpose

Cashu users should be able to use a clean wallet as part of their operating system instead of opening a separate wallet application. The defining experience is to glance at the wallet state, open an Omarchy-native panel, and complete a common Cashu action in seconds.

## MVP

- Detect a missing or incompatible `cocod-bin` installation and guide the user through setup.
- Provision one dedicated, independently supervised `cocod` Wallet Instance.
- Create a new empty wallet through explicit first-run onboarding.
- Show Wallet State, Spendable Balance, and Reserved Balance.
- Reveal the Recovery Phrase only after a deliberate warning and confirmation.
- Prepare pasted, sat-denominated Cashu tokens through cocod, review the safe Prepared Receive,
  and confirm or cancel it explicitly.
- Prepare and confirm a Send before creating its encoded Cashu token.
- Copy outgoing Cashu tokens explicitly without automatically reading or writing the clipboard.
- Recover Active Transfers and allow a Pending Send to be reopened or reclaimed.
- Compose the current Wallet view from canonical `cocod` resources and refresh it from safe
  invalidation events.
- Keep balances out of the bar; clicking its state indicator opens the panel.
- Preserve the Wallet Instance and its data if the Quickshell plugin is removed.

The interface follows Omarchy's theme primitives, spacing, typography, and interaction conventions. Cashu identity is restrained to the product name and wallet icon.

## Architecture

One Wallet uses one dedicated `cocod` process. `cocod` is the sole custody boundary and system of record; it owns the Recovery Phrase, proofs, persistence, balances, and transfer operations.

The `cocod` process runs as a session-scoped systemd user service. It survives shell and plugin reloads, restarts on failure, and stops with the user's session. Systemd lingering is not enabled.

The plugin has three Quickshell entry points:

- A `bar-widget` showing wallet state and opening the panel.
- A `panel` containing setup, wallet state, balances, Receive, Send, recovery material, and Active Transfers.
- A headless `service` acting as the Shell Adapter shared by the bar widget and panel.

The Shell Adapter uses versioned HTTP/JSON over loopback TCP for commands and canonical resource
fetches, plus Server-Sent Events for invalidation. It composes the Wallet Client's view from the
separate status, balance, mint, and operation resources. SSE payloads are non-authoritative hints
with safe resource identifiers only; they cause the relevant resources to be fetched again. V1 has
no event IDs, revision-gap protocol, or replay, so the adapter refetches every relevant resource on
startup and reconnect. Secrets, proofs, encoded tokens, and balances are never broadcast through
the event stream. The adapter handles partial frames and backoff and accepts server rotation to
bound Qt's cumulative response buffer.

## Security boundary

The MVP does not include wallet passphrase protection. `cocod` must therefore enforce a private state directory with mode `0700` and sensitive files with mode `0600`. The Shell Adapter reads the administrative Client Credential only from `<state-root>/credentials/current/client` and authenticates every `/v1/*` request without exposing the credential to bar or panel code, diagnostics, URLs, arguments, or logs. The Wallet Client never persists the Recovery Phrase, Cashu tokens, proofs, or Client Credential.

The daemon binds to loopback only and defaults to `127.0.0.1:62626`. `/health` is public and minimal; every `/v1/*` resource is authenticated.

## Deferred

- Restore from a Recovery Phrase
- Passphrase protection and unlock UI
- Lightning invoice creation and payment
- Full transfer history and general mint management
- Multiple Wallet Instances
- Remote daemon connections
- Unix-socket compatibility
- QR-code input and output
- Camera scanning
- Desktop notifications
- Destructive reset or wallet deletion
- Non-sat Cashu units

## Publication blockers

- A versioned loopback TCP API lands in `cocod`.
- `cocod` enforces private state-directory and sensitive-file permissions.
- The daemon exposes durable Send and Receive preparation, execution, lookup, recovery, cancellation, and reclaim semantics.
- The daemon keeps Known Mint registration and explicit Mint trust separate.
- Interrupted Receive operations recover reliably after daemon restart.
- A standalone `cocod-bin` Arch/AUR package provides the executable and systemd user-service template.
- Quickshell integration tests verify incremental SSE consumption, reconnection, and bounded stream rotation across the supported Omarchy and Qt versions.

## Acceptance journey

1. Install the plugin and a compatible `cocod-bin`.
2. Provision the user service and create an empty Wallet.
3. Provision a Trusted Mint, then prepare, review, and confirm a Cashu token from it.
4. Observe the Spendable Balance update through SSE.
5. Prepare, confirm, and copy a Send.
6. Reload Omarchy and recover the Pending Send from `cocod`.
7. Observe redemption or attempt Reclaim.
8. Remove the UI plugin without deleting wallet state.

The MVP fulfills its purpose when this journey is reliable, private by default, and visually native to Omarchy.

## Domain language and decisions

Canonical project terminology lives in [`CONTEXT.md`](./CONTEXT.md). Durable architecture decisions live in [`docs/adr/`](./docs/adr/).

## Upstream references

The accepted and implemented cocod TCP resource surface is captured in the
[`Cocod Network Interface v1`](./docs/reference/cocod-network-interface-v1.md)
reference. Its provenance note pins the canonical `feat/cocod-api-v1-integration`
source revision and capture date. That branch now provides generated OpenAPI and
the complete base v1 resource surface; release and package publication remain
tracked by #14.

## Cocod v1 development

The mock-backed lifecycle and transfer foundation is complete in #15, #6, #5, and #7. The
development bridge implemented by [#16](https://github.com/Egge21M/omarchy-cashu/issues/16) runs
that client against canonical cocod source without making the plugin own the daemon process. Next,
[#14](https://github.com/Egge21M/omarchy-cashu/issues/14) publishes cocod and `cocod-bin`; #8 and
#9 then prove packaged connectivity and real Wallet lifecycle, followed by the real Receive (#10),
real Send/Reclaim (#11), and complete installable MVP (#12) acceptance journeys. GitHub's native
issue dependencies remain the live implementation gates.

The deterministic mock and Shell Adapter implement the Wallet Client's accepted product contract
on top of cocod v1. Bootstrap authenticates and reads `/v1/openapi.json`, then composes
the Wallet view from `/v1/status`, `/v1/balances`, `/v1/mints`, and the prepared
and in-flight Receive and Send Operation collections. Amounts stay decimal
integer strings through transport, aggregation, diagnostics, and display.

Wallet creation uses `POST /v1/admin/wallet/initialize`; separately confirmed
Recovery Phrase access uses `POST /v1/admin/wallet/recovery-material`. Both
sensitive responses are non-cacheable and their secret values are not retained
in adapter state. The mock starts without a Wallet and never initializes one on
startup, reconnect, shell reload, or panel open. Wallet actions remain
unavailable until the Cashu User initializes the Wallet.

The mock-backed Receive design keeps token material out of the adapter's projected state.
`POST /v1/operations/receive` validates and prepares the token inside cocod, returning only the
safe Prepared Receive document for review. Confirmation executes that Operation; cancellation
rolls it back. Success is reported only after refetching the finalized Operation and
`/v1/balances`. Encoded token text exists only in the focused input and immediate authenticated
preparation body; it is excluded from diagnostics IPC, adapter snapshots, SSE, logs, and persisted
plugin data. Prepared Receives are rediscovered from canonical collections after reload, and a
dropped preparation response is reconciled before the Wallet offers confirmation or cancellation.
If canonical preparation returns a non-sat unit, the client cancels that Prepared Receive instead
of labeling or executing it as sats.

Canonical v1 requires a Mint to be trusted before Receive preparation and does not reveal an
unknown Mint from a rejected token. The Wallet Client therefore cannot offer in-flow unknown-Mint
approval without decoding bearer tokens locally, which it deliberately does not do. The Cashu User
must establish trust through cocod before reviewing a token from that Mint.

Ordinary amount Send uses `POST /v1/operations/send`; cocod returns authoritative requested amount,
input amount, fee, and swap requirements for review. The Max affordance is deferred because v1 has
no daemon-calculated maximum and the Wallet Client does not estimate fees or select proofs. Untyped
preparation and Reclaim failures use canonical `coco_error`; the client refreshes Operation and
balance resources instead of inferring draft-specific causes from diagnostic text.

Authenticated `/v1/events` frames are safe invalidation hints. Balance, Known
Mint, and Operation hints refetch their affected canonical resources. Bootstrap,
reconnect, parse failure, and stream rotation refetch the full relevant set;
there is no event position, revision-gap handling, or replay.

Start the mock on its default loopback address after cocod (or a test fixture)
has provisioned `<state-root>/credentials/current/client`:

```bash
python3 scripts/mock-cocod.py
```

To replace the mock during development with a compatible local cocod source checkout, follow the
[local cocod development guide](./docs/development/local-cocod.md). The source-backed check is
opt-in; the deterministic mock remains the default fault-injection adapter and test dependency.

Run the repeatable static check from the repository root:

```bash
./scripts/smoke.sh
```

The smoke suite verifies the mock contract and runs a real incremental SSE
stream through the supported Quickshell/Qt runtime, including partial frames,
heartbeats, rotation, disconnect backoff, recovery, and compatibility errors.

For a live runtime check, install this repository at
`~/.config/omarchy/plugins/io.github.egge21m.omarchy-cashu`, rescan and enable
it, then exercise the same toggle path used by the bar:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.egge21m.omarchy-cashu --section right
./scripts/smoke.sh --live
```

The live smoke check does not alter configuration or Wallet State after
installation. With the mock running, it validates the loaded manifest and live
adapter state, then enters through the bar WidgetButton handler to open and
close the panel with the initiating-screen payload.
