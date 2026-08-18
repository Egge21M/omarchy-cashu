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
  }
}
