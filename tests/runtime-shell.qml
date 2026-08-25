import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
  PanelWindow {
    id: testBarWindow
    visible: true
    implicitHeight: 1
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    anchors {
      top: true
      left: true
      right: true
    }

    Item {
      id: testAnchor
      width: 1
      height: 1
    }
  }

  QtObject {
    id: testHostWidget
    property var anchorItem: testAnchor
    property bool popoutSwitchClosing: false
    // Keep incidental desktop pointer activity from dismissing the runtime fixture.
    function close() {}
  }

  QtObject {
    id: testBar
    property var shell: testShell
    property string position: "top"
    property bool vertical: false
    property int barSize: 1
    property color foreground: "white"
    property color barForeground: foreground
    property color background: "black"
    property bool foregroundAnimationEnabled: false
    property color urgent: "red"
    property string fontFamily: "sans-serif"
    property var activePopout: null

    function findPanelWidget(pluginId) { return testHostWidget }
    function moduleWidgets(pluginId) { return [testHostWidget] }
    function targetWindow(widget) { return testBarWindow }
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) {
      if (activePopout === owner) activePopout = null
    }
  }

  QtObject {
    id: testShell
    property var bar: testBar
    function hide(pluginId) { walletPanel.close() }
    function serviceFor(pluginId) { return adapter }
    function isPluginOpen(pluginId) { return walletPanel.opened }
    function summon(pluginId, payload) { walletPanel.open(payload) }
    function toggle(pluginId, payload) {
      if (walletPanel.opened) walletPanel.close()
      else walletPanel.open(payload)
    }
  }

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
    shell: testShell
  }

  BarWidget {
    id: walletBar
    bar: testBar
  }

  IpcHandler {
    target: "io.github.egge21m.omarchy-cashu.runtime-test"

    function panelSnapshot(): string {
      return walletPanel.smokeSnapshot()
    }

    function barSnapshot(): string {
      return walletBar.smokeSnapshot()
    }

    function openPanel(): string {
      walletPanel.open("{}")
      return "ok"
    }

    function closePanel(): string {
      return walletPanel.close() ? "ok" : "disabled"
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

    function prepareReceive(): string {
      return walletPanel.smokePrepareReceive()
    }

    function confirmReceive(): string {
      return walletPanel.smokeConfirmReceive()
    }

    function cancelReceive(): string {
      return walletPanel.smokeCancelReceive()
    }

    function openSend(): string {
      return walletPanel.smokeOpenSend()
    }

    function setSendAmount(amount: string): string {
      return walletPanel.smokeSetSendAmount(amount)
    }

    function selectSendMint(mintUrl: string): string {
      return walletPanel.smokeSelectSendMint(mintUrl)
    }

    function prepareSend(): string {
      return walletPanel.smokePrepareSend()
    }

    function cancelSend(): string {
      return walletPanel.smokeCancelSend()
    }

    function confirmSend(): string {
      return walletPanel.smokeConfirmSend()
    }

    function copySend(): string {
      return walletPanel.smokeCopySend()
    }

    function doneSend(): string {
      return walletPanel.smokeDoneSend()
    }

    function beginReclaimSend(): string {
      return walletPanel.smokeBeginReclaimSend()
    }

    function confirmReclaimSend(): string {
      return walletPanel.smokeConfirmReclaimSend()
    }

    function retrySend(): string {
      return walletPanel.smokeRetrySend()
    }

    function openActiveSends(): string {
      return walletPanel.smokeOpenActiveSends()
    }

    function selectActiveSend(operationId: string): string {
      return walletPanel.smokeSelectActiveSend(operationId)
    }

    function backActiveSends(): string {
      return walletPanel.smokeBackActiveSends()
    }
  }
}
