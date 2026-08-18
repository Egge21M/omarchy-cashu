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
- Receive pasted, sat-denominated Cashu tokens through preview and confirmation.
- Ask before trusting a mint introduced by an incoming token.
- Prepare and confirm a Send before creating its encoded Cashu token.
- Copy outgoing Cashu tokens explicitly without automatically reading or writing the clipboard.
- Recover Active Transfers and allow a Pending Send to be reopened or reclaimed.
- Synchronize authoritative snapshots and safe lifecycle events from `cocod`.
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

The Shell Adapter uses versioned HTTP/JSON over loopback TCP for commands and snapshots, plus Server-Sent Events for state and operation changes. SSE payloads contain revisions and safe lifecycle metadata only; secrets, proofs, encoded tokens, and balances are never broadcast through the event stream. The adapter takes a fresh snapshot on startup and reconnect, handles partial frames and backoff, and rotates the stream to bound Qt's cumulative response buffer.

## Security boundary

The MVP does not include wallet passphrase protection. `cocod` must therefore enforce a private state directory with mode `0700` and sensitive files with mode `0600`. The Wallet Client never persists the Recovery Phrase, Cashu tokens, proofs, or future transport credentials and never includes them in logs.

The daemon binds to loopback only. Transport authentication is defined by the redesigned `cocod` TCP API and must be supported before this plugin is published.

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
- Transport authentication is defined upstream.
- `cocod` enforces private state-directory and sensitive-file permissions.
- The daemon exposes durable Send and Receive preparation, execution, lookup, recovery, cancellation, and reclaim semantics.
- The daemon supports non-mutating token preview and explicit mint trust.
- Interrupted Receive operations recover reliably after daemon restart.
- A standalone `cocod-bin` Arch/AUR package provides the executable and systemd user-service template.
- Quickshell integration tests verify incremental SSE consumption, reconnection, and bounded stream rotation across the supported Omarchy and Qt versions.

## Acceptance journey

1. Install the plugin and a compatible `cocod-bin`.
2. Provision the user service and create an empty Wallet.
3. Receive a Cashu token and approve its previously unknown mint.
4. Observe the Spendable Balance update through SSE.
5. Prepare, confirm, and copy a Send.
6. Reload Omarchy and recover the Pending Send from `cocod`.
7. Observe redemption or attempt Reclaim.
8. Remove the UI plugin without deleting wallet state.

The MVP fulfills its purpose when this journey is reliable, private by default, and visually native to Omarchy.

## Domain language and decisions

Canonical project terminology lives in [`CONTEXT.md`](./CONTEXT.md). Durable architecture decisions live in [`docs/adr/`](./docs/adr/).

## Slice 1 development

Slice 1 is an intentionally fixture-backed Omarchy 4 Quattro shell. Its
headless service owns one shared Wallet State fixture; the bar shows only that
state, while the panel presents fixture balances and placeholders for setup,
Receive, Send, and Active Transfers. It does not connect to `cocod` or perform
wallet operations.

Run the repeatable static check from the repository root:

```bash
./scripts/smoke.sh
```

For a live runtime check, install this repository at
`~/.config/omarchy/plugins/io.github.egge21m.omarchy-cashu`, rescan and enable
it, then exercise the same toggle path used by the bar:

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.egge21m.omarchy-cashu --section right
./scripts/smoke.sh --live
```

The live smoke check does not alter configuration or Wallet State after
installation: it validates the loaded manifest, compares the service and panel
fixture revisions, and opens then closes the panel through the shell's toggle
contract.
