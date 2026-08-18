import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// On-demand panel entry point. The shell injects `shell`, `manifest`, and the
// matching service singleton. The live bar widget supplies the visual anchor,
// preserving Omarchy's bar-to-panel positioning and single-popout behavior.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false
  property bool popoutSwitchClosing: false

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "io.github.egge21m.omarchy-cashu"
  readonly property var stateOwner: service || (shell
    && typeof shell.serviceFor === "function" ? shell.serviceFor(pluginId) : null)
  property string requestedScreenName: ""
  property var hostWidget: null
  readonly property Item anchorItem: hostWidget && hostWidget.anchorItem
    ? hostWidget.anchorItem : null
  readonly property var activeTransfer: stateOwner
    && stateOwner.activeTransfers.length > 0 ? stateOwner.activeTransfers[0] : null

  readonly property color foreground: shell && shell.bar
    ? shell.bar.foreground : Color.foreground
  readonly property color urgent: shell && shell.bar
    ? shell.bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: shell && shell.bar
    ? shell.bar.fontFamily : Style.font.family

  function resolveHostWidget() {
    if (!shell || !shell.bar
        || typeof shell.bar.findPanelWidget !== "function") return null

    if (requestedScreenName && typeof shell.bar.moduleWidgets === "function"
        && typeof shell.bar.targetWindow === "function") {
      var widgets = shell.bar.moduleWidgets(pluginId)
      for (var i = 0; i < widgets.length; i++) {
        var widget = widgets[i]
        if (widgetScreenName(widget) === requestedScreenName) return widget
      }
    }

    return shell.bar.findPanelWidget(pluginId)
  }

  function widgetScreenName(widget) {
    if (!widget || !shell || !shell.bar
        || typeof shell.bar.targetWindow !== "function") return ""
    var window = shell.bar.targetWindow(widget)
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  function open(payloadJson) {
    requestedScreenName = ""
    try {
      var payload = JSON.parse(payloadJson || "{}")
      requestedScreenName = String(payload.screenName || "")
    } catch (error) {
      requestedScreenName = ""
    }
    hostWidget = resolveHostWidget()
    opened = true
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    opened = false
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function amountText(value) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return amount.toLocaleString(Qt.locale(), "f", 0) + " "
      + (stateOwner ? stateOwner.unit : "sat")
  }

  function smokeSnapshot(arg) {
    return JSON.stringify({
      opened: opened,
      anchored: !!anchorItem,
      requestedScreenName: requestedScreenName,
      anchorScreenName: widgetScreenName(hostWidget),
      fixtureId: stateOwner ? stateOwner.fixtureId : "",
      revision: stateOwner ? stateOwner.revision : 0,
      walletState: stateOwner ? stateOwner.walletState : "unavailable"
    })
  }

  Timer {
    id: anchorRetry
    interval: 100
    repeat: true
    running: root.opened && !root.hostWidget
    onTriggered: root.hostWidget = root.resolveHostWidget()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.shell ? root.shell.bar : null
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.dismiss()

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.spacing.panelGap

          PanelHero {
            width: parent.width
            title: "Cashu Wallet"
            meta: root.stateOwner
              ? root.stateOwner.walletStateDetail + " · " + root.stateOwner.walletStateLabel
              : "Wallet State unavailable"
            detail: root.stateOwner && root.stateOwner.fixtureBacked ? "FIXTURE" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: root.stateOwner ? root.stateOwner.walletStateGlyph : "󰅙"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "SETUP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.spacing.rowGap

              Text {
                text: "󰄬"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(32)
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: "Native shell ready"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  width: parent.width
                  text: "Fixture data only · cocod is not connected"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.spacing.panelGap

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(2)

                Text {
                  text: "SPENDABLE"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  text: root.amountText(root.stateOwner
                    ? root.stateOwner.spendableBalance : 0)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(2)

                Text {
                  text: "RESERVED"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  text: root.amountText(root.stateOwner
                    ? root.stateOwner.reservedBalance : 0)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "WALLET ACTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Receive"
                iconText: "󰑐"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: false
                opacity: 0.5
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Send"
                iconText: "󰒊"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: false
                opacity: 0.5
              }
            }

            Text {
              width: parent.width
              text: "Receive and Send are placeholders in this fixture-backed slice."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ACTIVE TRANSFERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              visible: !!root.activeTransfer
              width: parent.width
              spacing: Style.spacing.rowGap

              Text {
                text: "󰇚"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.iconLarge
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - transferAmount.implicitWidth - Style.space(42)
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: root.activeTransfer ? root.activeTransfer.stateLabel : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: root.activeTransfer
                    ? root.activeTransfer.detail + " · Fixture" : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              Text {
                id: transferAmount
                text: root.activeTransfer
                  ? root.amountText(root.activeTransfer.amount) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              visible: !root.activeTransfer
              width: parent.width
              text: "No Active Transfers"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
