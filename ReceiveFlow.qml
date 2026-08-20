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
  property bool mintApproved: false
  property bool confirmationPending: false

  readonly property string receiveState: service
    ? String(service.receiveState || "idle") : "idle"
  readonly property string viewState: !opened ? "closed"
    : receiveState === "idle" ? "entry" : receiveState
  readonly property bool textPresent: tokenInput.text.trim().length > 0
  readonly property bool inputVisible: viewState === "entry"
  readonly property bool pasteVisible: viewState === "entry"
  readonly property bool inputFocused: tokenInput.focus || tokenInput.activeFocus
  readonly property var preview: service ? service.receivePreview : null
  readonly property string error: service ? service.receiveError : ""
  readonly property bool approvalVisible: viewState === "preview"
    && preview && !preview.trusted
  readonly property bool confirmEnabled: viewState === "preview"
    && preview && (preview.trusted || mintApproved)

  implicitHeight: content.implicitHeight
  visible: viewState !== "closed"

  function clearInput() {
    tokenInput.text = ""
    mintApproved = false
    confirmationPending = false
  }

  function open() {
    if (!service || !service.resetReceive()) return false
    clearInput()
    opened = true
    Qt.callLater(function() { tokenInput.forceActiveFocus() })
    return true
  }

  function close() {
    if (service && !service.resetReceive()) return false
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
    return service.previewReceive(tokenInput.text)
  }

  function toggleMintApproval() {
    if (!approvalVisible) return false
    mintApproved = !mintApproved
    return true
  }

  function confirm() {
    if (!confirmEnabled || !service) return false
    if (preview.trusted) {
      if (!service.confirmReceive(tokenInput.text)) return false
      clearInput()
      return true
    }
    confirmationPending = true
    if (!service.approveReceiveMint()) {
      confirmationPending = false
      return false
    }
    return true
  }

  function continueAfterMintApproval() {
    if (!confirmationPending || receiveState !== "preview" || !preview
        || !preview.trusted || !service) return
    confirmationPending = false
    if (service.confirmReceive(tokenInput.text)) clearInput()
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

  onReceiveStateChanged: {
    if (receiveState === "error") clearInput()
    else if (receiveState === "preview") {
      if (confirmationPending && preview && preview.trusted)
        Qt.callLater(root.continueAfterMintApproval)
      else mintApproved = false
    }
  }

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
      text: "Enter a Cashu token to preview its amount, mint, and fee."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      visible: ["previewing", "approving", "preparing", "executing", "reconciling"]
        .indexOf(root.viewState) !== -1
      width: parent.width
      text: root.viewState === "previewing" ? "Checking token…"
        : root.viewState === "approving" ? "Approving mint…"
        : root.viewState === "preparing" ? "Preparing Receive…"
        : root.viewState === "executing" ? "Receiving ecash…"
        : "Confirming with cocod…"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
    }

    Column {
      visible: root.viewState === "preview" && !!root.preview
      width: parent.width
      spacing: Style.spacing.labelGap

      Text {
        width: parent.width
        text: root.preview ? root.amountText(root.preview.amount) + " sat" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: parent.width
        text: root.preview ? "Mint · " + root.preview.mintUrl : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WrapAnywhere
      }

      Text {
        width: parent.width
        text: root.preview ? "Fee · " + root.amountText(root.preview.fee)
          + " sat · You receive " + root.amountText(root.preview.netAmount) + " sat" : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        text: root.preview && root.preview.trusted
          ? "This mint is already trusted."
          : "This mint is not trusted yet. Approve it only if you recognize it."
        color: root.preview && root.preview.trusted ? root.dim : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: root.preview && !root.preview.trusted
        wrapMode: Text.WordWrap
      }
    }

    Button {
      visible: root.approvalVisible
      text: root.mintApproved ? "Mint approved" : "Approve this mint"
      iconText: root.mintApproved ? "󰄬" : "󰔶"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      selected: root.mintApproved
      onClicked: root.toggleMintApproval()
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
      visible: root.viewState === "preview"
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
      visible: root.viewState === "entry" || root.viewState === "preview"
      text: "Cancel"
      iconText: "󰅖"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.close()
    }
  }
}
