# Run the Wallet Client against local cocod source

The Wallet Client can use a compatible local `cashubtc/coco` source checkout before the standalone
`cocod-bin` package is published. This is a development adapter at the existing network seam: the
Wallet Client still communicates only through authenticated HTTP/JSON and SSE and never imports,
vendors, launches, or owns cocod code.

The checkout must be the Coco monorepo containing `packages/cocod` and the v1 TCP implementation.
The older standalone, socket-era cocod repository is intentionally rejected by the launcher.

## Prepare the source checkout

From the compatible Coco repository root:

```bash
bun install
bun run build
```

The build is explicit so starting the Wallet Instance never downloads dependencies or mutates the
source checkout unexpectedly.

## Run an isolated development Wallet Instance

From the Wallet Client repository root:

```bash
COCO_REPO=/absolute/path/to/coco
WALLET_INSTANCE_HOME="$HOME/.local/state/omarchy-cashu/cocod-dev"
WALLET_STATE_ROOT="$WALLET_INSTANCE_HOME/.cocod"
COCOD_DEV_PORT=62627

./scripts/run-local-cocod.sh \
  --repo "$COCO_REPO" \
  --state-root "$WALLET_STATE_ROOT" \
  --port "$COCOD_DEV_PORT"
```

Canonical cocod always resolves its state at `$HOME/.cocod`. The launcher sets `HOME` to the
dedicated parent of the requested `--state-root`, stays in the foreground, and prints the two
non-secret settings that the Wallet Client must inherit:

```text
COCOD_STATE_DIR=/absolute/development/instance-home/.cocod
OMARCHY_CASHU_DAEMON_URL=http://127.0.0.1:62627
```

Set those values in the process environment before starting or restarting the development Omarchy
shell. The Shell Adapter then discovers the administrative Client Credential from
`$COCOD_STATE_DIR/credentials/current/client`; the launcher never prints it.

`COCOD_STATE_DIR` is a Wallet Client discovery override; cocod itself does not implement that
environment variable. Using state root `$HOME/.cocod` and port `62626` matches both programs'
defaults and needs no shell environment override. Do that only when the directory is intentionally
dedicated to this development Wallet Instance. The isolated home above is safer for routine work.

## Keep cocod independent of the UI

For a daemon that survives the terminal and Wallet Client reloads, let the systemd user manager own
the same foreground launcher:

```bash
WALLET_CLIENT_REPO=/absolute/path/to/omarchy-cashu
COCO_REPO=/absolute/path/to/coco
WALLET_INSTANCE_HOME="$HOME/.local/state/omarchy-cashu/cocod-dev"
WALLET_STATE_ROOT="$WALLET_INSTANCE_HOME/.cocod"
COCOD_DEV_PORT=62627

systemd-run --user \
  --unit=omarchy-cashu-cocod-dev \
  --collect \
  --property=Restart=on-failure \
  --setenv=PATH="$PATH" \
  "$WALLET_CLIENT_REPO/scripts/run-local-cocod.sh" \
    --repo "$COCO_REPO" \
    --state-root "$WALLET_STATE_ROOT" \
    --port "$COCOD_DEV_PORT"
```

Inspect or stop it independently:

```bash
journalctl --user -u omarchy-cashu-cocod-dev -f
systemctl --user stop omarchy-cashu-cocod-dev
```

When `cocod-bin` ships, the permanent user-service template replaces the source launcher with the
packaged executable. The Wallet Client transport and state projection do not change.

## Run the opt-in source integration

The integration check creates a temporary Wallet Instance, starts cocod from source, connects the
real QML Shell Adapter, creates the Wallet, checks public v1 resources and authenticated SSE, closes
the Wallet Client without stopping cocod, requests graceful process shutdown, and removes only its
temporary state root:

```bash
./tests/local-cocod.sh --repo "$COCO_REPO"
```

It does not execute Receive or Send and therefore never requires real-value ecash. The deterministic
mock remains the default adapter for fault injection, partial SSE frames, Operation races, and the
normal smoke suite.

## Current transfer gaps

The canonical v1 OpenAPI currently has neither the non-mutating `/v1/token-previews` resource nor
the daemon-calculated `/v1/operations/send/max` resource assumed by the accepted Wallet Client
Receive and Send designs. The Shell Adapter discovers those optional paths from OpenAPI and keeps
the corresponding UI actions disabled when they are absent. It does not decode bearer tokens or
calculate proof selection locally to compensate.

The source-backed test therefore accepts Wallet lifecycle, balances, Known Mints, durable Operation
collections, and SSE against the canonical branch without claiming the transfer UX is ready.
Resolving these two product/API gaps belongs upstream before the real Receive and Send acceptance
tests replace the deterministic mock. Release and package publication remain tracked by issue #14.
