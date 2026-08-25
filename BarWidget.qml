import QtQuick
import qs.Commons
import qs.Ui

// The bar intentionally exposes Wallet State, never balance. Its popup shape
// methods let the Omarchy bar locate this instance and coordinate it with all
// other native bar panels, while the actual panel stays an on-demand entry
// point owned by the shell host.
BarWidget {
  id: root
  moduleName: "io.github.egge21m.omarchy-cashu"

  readonly property var stateOwner: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property string stateLabel: stateOwner
    ? stateOwner.barStateLabel : "Unavailable"
  readonly property string stateGlyph: stateOwner
    ? stateOwner.barStateGlyph : "󰅙"

  readonly property bool opened: bar && bar.shell
    ? bar.shell.isPluginOpen(root.moduleName) : false
  property bool popoutSwitchClosing: false
  readonly property Item anchorItem: button

  function panelPayload() {
    var window = bar && typeof bar.targetWindow === "function"
      ? bar.targetWindow(root) : null
    var screenName = window && window.screen
      ? String(window.screen.name || "") : ""
    return JSON.stringify({ screenName: screenName })
  }

  function open() {
    if (bar && bar.shell) bar.shell.summon(root.moduleName, panelPayload())
  }

  function close() {
    if (bar && bar.shell) bar.shell.hide(root.moduleName)
  }

  function togglePanel() {
    if (bar && bar.shell) bar.shell.toggle(root.moduleName, panelPayload())
  }

  // Repeatable live smoke coverage enters through WidgetButton's public press
  // path, so it exercises this handler and the initiating-screen payload.
  function smokeLeftClick() {
    button.triggerPress(Qt.LeftButton)
  }

  function smokeSnapshot() {
    return JSON.stringify({
      stateLabel: stateLabel,
      text: button.text,
      tooltipText: button.tooltipText
    })
  }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? root.stateGlyph : root.stateGlyph + "  " + root.stateLabel
    fontSize: Style.font.body
    active: root.stateOwner
      && (root.stateOwner.barAttention || root.stateOwner.barActive)
    tooltipText: "Cashu Wallet — " + root.stateLabel
      + (root.stateOwner && root.stateOwner.barActive ? " · Active Transfer" : "")

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }
}
