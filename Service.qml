import QtQuick
import Quickshell.Io

// Slice 1's headless Shell Adapter. It is deliberately fixture-backed: this
// single object owns the Wallet State consumed by both the bar and the panel,
// without performing process execution, networking, file IO, or persistence.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.egge21m.omarchy-cashu"
  readonly property string diagnosticsTarget: pluginId + ".state"
  readonly property string fixtureId: "slice-1-wallet-state"
  readonly property int revision: 1
  readonly property bool fixtureBacked: true

  readonly property string walletState: "unlocked"
  readonly property string walletStateLabel: "Unlocked"
  readonly property string walletStateDetail: "Fixture Wallet Instance"
  readonly property string walletStateGlyph: "󰖄"

  readonly property int spendableBalance: 42000
  readonly property int reservedBalance: 7000
  readonly property string unit: "sat"

  readonly property var activeTransfers: [
    {
      id: "fixture-send-1",
      kind: "send",
      state: "pending-send",
      stateLabel: "Pending Send",
      amount: 7000,
      detail: "Awaiting redemption"
    }
  ]

  function snapshot() {
    return {
      fixtureId: fixtureId,
      revision: revision,
      fixtureBacked: fixtureBacked,
      walletState: walletState,
      walletStateLabel: walletStateLabel,
      spendableBalance: spendableBalance,
      reservedBalance: reservedBalance,
      unit: unit,
      activeTransfers: activeTransfers
    }
  }

  function snapshotJson() {
    return JSON.stringify(snapshot())
  }

  // A narrow diagnostics target keeps the live smoke check read-only. It does
  // not expose secrets or mutate Wallet State.
  IpcHandler {
    target: root.diagnosticsTarget

    function snapshot(): string {
      return root.snapshotJson()
    }

    function panelOpen(): string {
      return root.shell && typeof root.shell.isPluginOpen === "function"
        && root.shell.isPluginOpen(root.pluginId) ? "true" : "false"
    }
  }
}
