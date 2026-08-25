import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Focused Receive module. The encoded token exists only in this input control
// and the immediate command argument passed to the Shell Adapter.
Item {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.45)
  property string fontFamily: Style.font.family
  property bool opened: false
  property int clipboardReads: 0

  readonly property string receiveState: service
    ? String(service.receiveState || "idle") : "idle"
  readonly property string viewState: !opened ? "closed"
    : receiveState === "idle" ? "entry" : receiveState
  readonly property bool textPresent: tokenInput.text.trim().length > 0
  readonly property bool inputVisible: viewState === "entry"
  readonly property bool pasteVisible: viewState === "entry"
  readonly property bool inputFocused: tokenInput.focus || tokenInput.activeFocus
  readonly property var prepared: service ? service.receivePreparedOperation : null
  readonly property string error: service ? service.receiveError : ""
  readonly property bool confirmEnabled: viewState === "review" && !!prepared

  implicitHeight: content.implicitHeight
  visible: viewState !== "closed"

  function clearInput() {
    tokenInput.text = ""
  }

  function open() {
    if (!service || !service.beginReceiveFlow()) return false
    clearInput()
    opened = true
    Qt.callLater(function() { tokenInput.forceActiveFocus() })
    return true
  }

  function close() {
    if (service && !service.dismissReceiveFlow()) return false
    clearInput()
    opened = false
    return true
  }

  function panelClosed() {
    return close()
  }

  function paste() {
    if (viewState !== "entry") return false
    clipboardReads++
    tokenInput.text = String(Quickshell.clipboardText || "")
    return true
  }

  function review() {
    if (viewState !== "entry" || !textPresent || !service) return false
    if (!service.prepareReceive(tokenInput.text)) return false
    clearInput()
    return true
  }

  function confirm() {
    if (!confirmEnabled || !service) return false
    return service.confirmReceive()
  }

  function backToEntry() {
    if (!service || !service.resetReceive()) return false
    clearInput()
    Qt.callLater(function() { tokenInput.forceActiveFocus() })
    return true
  }

  function amountText(value) {
    var digits = String(value === undefined || value === null ? "0" : value)
    if (!/^(0|[1-9][0-9]*)$/.test(digits)) digits = "0"
    var firstGroup = digits.length % 3
    if (firstGroup === 0) firstGroup = 3
    var formatted = digits.slice(0, firstGroup)
    for (var index = firstGroup; index < digits.length; index += 3)
      formatted += "," + digits.slice(index, index + 3)
    return formatted
  }

  onReceiveStateChanged: if (receiveState === "error") clearInput()

  Column {
    id: content
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader {
      text: "RECEIVE ECASH"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      text: "Enter a Cashu token from a previously Trusted Mint. cocod prepares it before showing the amount and fee."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      visible: ["preparing", "cancelling", "executing", "reconciling"]
        .indexOf(root.viewState) !== -1
      width: parent.width
      text: root.viewState === "preparing" ? "Preparing Receive…"
        : root.viewState === "cancelling" ? "Cancelling Prepared Receive…"
        : root.viewState === "executing" ? "Receiving ecash…"
        : "Confirming with cocod…"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
    }

    Column {
      visible: root.viewState === "review" && !!root.prepared
      width: parent.width
      spacing: Style.spacing.labelGap

      Text {
        width: parent.width
        text: root.prepared ? root.amountText(root.prepared.amount) + " sat" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: parent.width
        text: root.prepared ? "Mint · " + root.prepared.mintUrl : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WrapAnywhere
      }

      Text {
        width: parent.width
        text: root.prepared ? "Fee · " + root.amountText(root.prepared.fee) + " sat" : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        text: "cocod prepared this Receive using a previously Trusted Mint."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    TextField {
      id: tokenInput
      width: parent.width
      visible: root.inputVisible
      placeholderText: "Cashu token"
      foreground: root.foreground
      font.family: root.fontFamily
    }

    Row {
      visible: root.inputVisible
      width: parent.width
      spacing: Style.spacing.controlGap

      Button {
        width: (parent.width - parent.spacing) / 2
        text: "Paste"
        iconText: "󰆒"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.paste()
      }

      Button {
        width: (parent.width - parent.spacing) / 2
        text: "Review"
        iconText: "󰄬"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.textPresent && root.viewState === "entry"
        opacity: enabled ? 1 : 0.5
        onClicked: root.review()
      }
    }

    Button {
      visible: root.viewState === "review"
      text: "Confirm Receive"
      iconText: "󰄬"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.confirmEnabled
      opacity: enabled ? 1 : 0.5
      onClicked: root.confirm()
    }

    Text {
      visible: root.viewState === "error" && root.error !== ""
      width: parent.width
      text: root.error
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      visible: root.viewState === "success"
      width: parent.width
      text: "Ecash received. Your Spendable Balance is up to date."
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
    }

    Button {
      visible: root.viewState === "error" || root.viewState === "success"
      text: root.viewState === "success" ? "Done" : "Back"
      iconText: "󰁍"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.viewState === "success" ? root.close() : root.backToEntry()
    }

    Button {
      visible: root.viewState === "entry" || root.viewState === "review"
      text: "Cancel"
      iconText: "󰅖"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.close()
    }
  }
}
