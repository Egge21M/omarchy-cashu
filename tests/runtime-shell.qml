import Quickshell
import Quickshell.Io

ShellRoot {
  Service {
    id: adapter
    reconnectBaseMs: 120
    reconnectMaximumMs: 960
    streamRotationMs: 60000
    heartbeatTimeoutMs: 1200
  }

  Panel {
    id: walletPanel
    service: adapter
  }

  IpcHandler {
    target: "io.github.egge21m.omarchy-cashu.runtime-test"

    function panelSnapshot(): string {
      return walletPanel.smokeSnapshot()
    }

    function openPanel(): string {
      walletPanel.open("{}")
      return "ok"
    }

    function closePanel(): string {
      walletPanel.close()
      return "ok"
    }

    function createWallet(): string {
      return walletPanel.smokeCreateWallet()
    }

    function createWalletFromAdapter(): string {
      return adapter.createWallet() ? "ok" : "disabled"
    }

    function openRecoveryPhrase(): string {
      walletPanel.open("{}")
      return walletPanel.smokeOpenRecoveryPhrase()
    }

    function confirmRecoveryPhrase(): string {
      walletPanel.open("{}")
      return walletPanel.smokeConfirmRecoveryPhrase()
    }

    function leaveRecoveryPhrase(): string {
      walletPanel.open("{}")
      return walletPanel.smokeLeaveRecoveryPhrase()
    }

    function openReceive(): string {
      return walletPanel.smokeOpenReceive()
    }

    function pasteReceive(): string {
      return walletPanel.smokePasteReceive()
    }

    function previewReceive(): string {
      return walletPanel.smokePreviewReceive()
    }

    function approveReceiveMint(): string {
      return walletPanel.smokeApproveReceiveMint()
    }

    function confirmReceive(): string {
      return walletPanel.smokeConfirmReceive()
    }

    function cancelReceive(): string {
      return walletPanel.smokeCancelReceive()
    }
  }
}
