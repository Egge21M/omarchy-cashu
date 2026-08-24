import Quickshell
import Quickshell.Io

ShellRoot {
  Service {
    id: adapter
    reconnectBaseMs: 100
    reconnectMaximumMs: 800
    streamRotationMs: 60000
    heartbeatTimeoutMs: 20000
  }

  IpcHandler {
    target: "io.github.egge21m.omarchy-cashu.local-cocod-test"

    function snapshot(): string {
      return adapter.snapshotJson()
    }

    function createWallet(): string {
      return adapter.createWallet() ? "ok" : "disabled"
    }

    function canonicalDtosCompatible(): string {
      var receive = {
        id: "receive-canonical", type: "receive", state: "prepared",
        mintUrl: "https://mint.canonical.test", unit: "sat", amount: "40", fee: "1",
        createdAt: "2026-08-20T12:00:00.000Z",
        updatedAt: "2026-08-20T12:00:00.000Z"
      }
      var send = {
        id: "send-canonical", type: "send", state: "prepared",
        mintUrl: "https://mint.canonical.test", unit: "sat", method: "default",
        requestedAmount: "42", fee: "1", inputAmount: "43", needsSwap: true,
        createdAt: "2026-08-20T12:00:00.000Z",
        updatedAt: "2026-08-20T12:00:00.000Z"
      }
      var valid = adapter.isReceiveOperation(receive)
        && adapter.isOperationCollection({items: [receive], offset: 0, limit: 50}, "receive")
        && adapter.isSendOperation(send)
        && adapter.isOperationCollection({items: [send], offset: 0, limit: 50}, "send")
        && adapter.operationAmount(send) === "42"
        && adapter.projectSendOperation(send).amount === "42"
        && adapter.normalizeNetworkErrorCode("not_found") === "operation_not_found"
        && adapter.normalizeNetworkErrorCode("invalid_operation_state") === "operation_conflict"
        && adapter.normalizeNetworkErrorCode("operation_result_not_available")
          === "result_not_available"
      return valid ? "ok" : "invalid"
    }
  }
}
