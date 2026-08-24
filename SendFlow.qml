import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Focused Send presentation module. cocod and the Shell Adapter own every
// calculation and Operation transition; this module owns only explicit user
// intent and, after execution, the short-lived token offered for copying.
Item {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.45)
  property string fontFamily: Style.font.family
  property bool opened: false
  property string selectedMintUrl: ""
  property string maxRequestMintUrl: ""
  property string visibleMaxMintUrl: ""
  property string outgoingToken: ""
  property int clipboardWrites: 0
  property bool reclaimWarningVisible: false
  readonly property string reclaimWarning: "Reclaim may race with recipient redemption. The recipient can still win while cocod checks the Mint."

  readonly property string sendState: service
    ? String(service.sendState || "idle") : "idle"
  readonly property string viewState: !opened ? "closed" : reclaimWarningVisible
    ? "reclaim-warning" : sendState === "idle" ? "entry" : sendState
  readonly property string amount: amountInput.text
  readonly property bool amountValid: /^[1-9][0-9]*$/.test(amount)
  readonly property bool inputVisible: viewState === "entry"
  readonly property bool inputFocused: amountInput.focus || amountInput.activeFocus
  readonly property var mintOptions: service
    && typeof service.sendMintOptions === "function"
    ? service.sendMintOptions(amount) : []
  readonly property bool refreshedMaxAvailable: viewState === "error"
    && service && String(service.sendErrorCode || "") === "insufficient_balance"
    && service.sendMaxResource
    && String(service.sendMaxResource.mintUrl || "") === selectedMintUrl
    && /^[1-9][0-9]*$/.test(String(service.sendMaxResource.maxAmount || ""))
  readonly property string maxAmount: service && service.sendMaxResource
    && (visibleMaxMintUrl === selectedMintUrl || refreshedMaxAvailable)
    && String(service.sendMaxResource.mintUrl || "") === selectedMintUrl
    ? String(service.sendMaxResource.maxAmount || "") : ""
  readonly property var prepared: service ? service.sendPreparedOperation : null
  readonly property var reviewBalance: service && prepared
    && typeof service.sendBalanceForMint === "function"
    ? service.sendBalanceForMint(prepared.mintUrl) : null
  readonly property string error: service ? String(service.sendError || "") : ""
  readonly property bool commandsAvailable: service
    && service.sendCommandsAvailable !== false
  readonly property bool prepareEnabled: viewState === "entry" && amountValid
    && selectedMintUrl !== "" && commandsAvailable
  readonly property bool confirmEnabled: viewState === "review" && commandsAvailable
  readonly property bool copyAvailable: viewState === "result" && outgoingToken !== ""
  readonly property bool reclaimAvailable: service
    && service.sendCanReclaim === true
    && ["result", "pending", "error"].indexOf(sendState) !== -1

  implicitHeight: content.implicitHeight
  visible: viewState !== "closed"

  function updateMintSelection() {
    var selectedStillEligible = service && service.sendMaxResource
      && typeof service.isTrustedSendMint === "function"
      && service.isTrustedSendMint(selectedMintUrl)
      && visibleMaxMintUrl === selectedMintUrl
      && String(service.sendMaxResource.mintUrl || "") === selectedMintUrl
      && String(service.sendMaxResource.maxAmount || "") === String(amountInput.text)
    for (var index = 0; index < mintOptions.length; index++)
      if (String(mintOptions[index].mintUrl || "") === selectedMintUrl)
        selectedStillEligible = true
    if (mintOptions.length === 1)
      selectedMintUrl = String(mintOptions[0].mintUrl || "")
    else if (!selectedStillEligible) selectedMintUrl = ""
  }

  function open() {
    if (!service || !service.beginSendFlow()) return false
    amountInput.text = ""
    selectedMintUrl = ""
    maxRequestMintUrl = ""
    visibleMaxMintUrl = ""
    outgoingToken = ""
    clipboardWrites = 0
    reclaimWarningVisible = false
    opened = true
    updateMintSelection()
    Qt.callLater(function() {
      if (root.opened && root.viewState === "entry")
        amountInput.forceActiveFocus()
    })
    return true
  }

  function close() {
    if (service && !service.dismissSendFlow()) return false
    amountInput.focus = false
    amountInput.text = ""
    selectedMintUrl = ""
    maxRequestMintUrl = ""
    visibleMaxMintUrl = ""
    outgoingToken = ""
    reclaimWarningVisible = false
    opened = false
    return true
  }

  function panelClosed() {
    amountInput.focus = false
    outgoingToken = ""
    reclaimWarningVisible = false
    if (service && !service.dismissSendFlow()) return false
    amountInput.text = ""
    selectedMintUrl = ""
    maxRequestMintUrl = ""
    visibleMaxMintUrl = ""
    opened = false
    return true
  }

  function setAmount(value) {
    if (viewState !== "entry") return false
    amountInput.text = String(value === undefined || value === null ? "" : value)
    return true
  }

  function selectMint(mintUrl) {
    if (viewState !== "entry") return false
    var selected = String(mintUrl || "")
    for (var index = 0; index < mintOptions.length; index++)
      if (String(mintOptions[index].mintUrl || "") === selected) {
        selectedMintUrl = selected
        return true
      }
    return false
  }

  function useMax() {
    if (viewState !== "entry" || !selectedMintUrl || !service) return false
    if (!commandsAvailable) return false
    maxRequestMintUrl = selectedMintUrl
    if (service.requestSendMax(maxRequestMintUrl)) return true
    maxRequestMintUrl = ""
    return false
  }

  function applyRequestedMax() {
    if (!service || !service.sendMaxResource || !maxRequestMintUrl) return
    var mintUrl = String(service.sendMaxResource.mintUrl || "")
    if (mintUrl !== maxRequestMintUrl) return
    maxRequestMintUrl = ""
    if (viewState !== "entry" || selectedMintUrl !== mintUrl) return
    visibleMaxMintUrl = mintUrl
    amountInput.text = String(service.sendMaxResource.maxAmount || "")
  }

  function useRefreshedMax() {
    if (!refreshedMaxAvailable || !service
        || typeof service.resumeSendAfterInsufficientBalance !== "function") return false
    var resource = service.sendMaxResource
    var mintUrl = String(resource.mintUrl || "")
    var amount = String(resource.maxAmount || "")
    if (!service.resumeSendAfterInsufficientBalance()) return false
    maxRequestMintUrl = ""
    amountInput.text = amount
    selectedMintUrl = mintUrl
    visibleMaxMintUrl = mintUrl
    Qt.callLater(function() {
      if (root.opened && root.viewState === "entry") amountInput.forceActiveFocus()
    })
    return true
  }

  function prepare() {
    if (!prepareEnabled || !service
        || typeof service.prepareSend !== "function") return false
    var started = service.prepareSend(selectedMintUrl, amount)
    if (started) amountInput.focus = false
    return started
  }

  function cancel() {
    if (!service || typeof service.cancelSendFlow !== "function") return false
    var outcome = String(service.cancelSendFlow() || "")
    if (outcome === "dismissed") {
      amountInput.focus = false
      amountInput.text = ""
      selectedMintUrl = ""
      maxRequestMintUrl = ""
      visibleMaxMintUrl = ""
      outgoingToken = ""
      opened = false
    }
    return outcome !== ""
  }

  function confirm() {
    if (!confirmEnabled || !service) return false
    return service.executePreparedSend()
  }

  function copyToken() {
    if (!copyAvailable) return false
    Quickshell.clipboardText = outgoingToken
    clipboardWrites++
    return true
  }

  function done() {
    return close()
  }

  function beginReclaim() {
    if (!reclaimAvailable) return false
    reclaimWarningVisible = true
    return true
  }

  function confirmReclaim() {
    if (!reclaimWarningVisible || !service
        || typeof service.reclaimPendingSend !== "function") return false
    reclaimWarningVisible = false
    outgoingToken = ""
    return service.reclaimPendingSend()
  }

  function retryPending() {
    if (!service || !service.sendPendingOperation
        || typeof service.retrievePendingSendResult !== "function") return false
    return service.retrievePendingSendResult(service.sendPendingOperation.id)
  }

  onMintOptionsChanged: {
    if (viewState === "entry") updateMintSelection()
  }
  onViewStateChanged: {
    if (viewState === "entry") updateMintSelection()
    if (["result", "reclaim-warning"].indexOf(viewState) === -1)
      outgoingToken = ""
  }
  onSelectedMintUrlChanged: {
    if (visibleMaxMintUrl !== selectedMintUrl) visibleMaxMintUrl = ""
  }
  onInputVisibleChanged: {
    if (!inputVisible) amountInput.focus = false
  }
  Connections {
    target: root.service
    ignoreUnknownSignals: true

    function onSendExecuted(token) {
      if (!root.opened || root.viewState !== "result") return
      root.outgoingToken = String(token || "")
    }

    function onSendMaxResourceChanged() {
      root.applyRequestedMax()
    }
  }

  Column {
    id: content
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader {
      text: "SEND ECASH"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      text: "Choose a Trusted Mint and enter a whole sat amount. cocod calculates Max, fees, and proof selection."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      visible: ["maxing", "preparing", "cancelling", "executing",
        "recovering-result", "reclaiming"]
        .indexOf(root.viewState) !== -1
      width: parent.width
      text: root.viewState === "maxing" ? "Calculating Send Max with cocod…"
        : root.viewState === "preparing" ? "Preparing Send and reserving ecash…"
        : root.viewState === "cancelling" ? "Cancelling Prepared Send…"
        : root.viewState === "recovering-result" ? "Recovering Pending Send…"
        : root.viewState === "reclaiming" ? "Attempting Reclaim with cocod…"
        : "Creating outgoing ecash…"
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
        text: root.prepared && root.service
          ? String(root.service.operationAmount(root.prepared) || "0") + " sat" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        width: parent.width
        text: root.prepared ? "Mint · " + String(root.prepared.mintUrl || "") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WrapAnywhere
      }

      Text {
        width: parent.width
        text: root.prepared ? "Fee · " + String(root.prepared.fee || "0")
          + " sat · Reserved input " + String(root.prepared.inputAmount || "0")
          + " sat" : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        text: root.reviewBalance ? "After preparation · "
          + String(root.reviewBalance.spendable || "0") + " sat spendable · "
          + String(root.reviewBalance.reserved || "0") + " sat reserved" : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: root.prepared && root.prepared.needsSwap === true
        width: parent.width
        text: "cocod will swap the selected inputs as part of this Send."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    TextField {
      id: amountInput
      width: parent.width
      visible: root.inputVisible
      placeholderText: "Amount in sats"
      foreground: root.foreground
      font.family: root.fontFamily
      inputMethodHints: Qt.ImhDigitsOnly
      onTextChanged: root.updateMintSelection()
    }

    Column {
      visible: root.inputVisible && root.mintOptions.length > 0
      width: parent.width
      spacing: Style.spacing.labelGap

      Text {
        width: parent.width
        text: root.mintOptions.length === 1 ? "TRUSTED MINT" : "CHOOSE A TRUSTED MINT"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Repeater {
        model: root.mintOptions

        Button {
          required property var modelData
          width: parent ? parent.width : 0
          text: String(modelData.name || modelData.mintUrl) + " · "
            + String(modelData.spendable || "0") + " sat spendable"
          iconText: root.selectedMintUrl === String(modelData.mintUrl || "") ? "󰄬" : "󰘔"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          selected: root.selectedMintUrl === String(modelData.mintUrl || "")
          onClicked: root.selectMint(modelData.mintUrl)
        }
      }
    }

    Text {
      visible: root.inputVisible && root.mintOptions.length === 0
      width: parent.width
      text: root.amountValid
        ? "No Trusted Mint has enough Spendable Balance for this amount."
        : "Enter a positive whole sat amount."
      color: root.amountValid ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      visible: (root.inputVisible || root.refreshedMaxAvailable)
        && root.maxAmount !== ""
      width: parent.width
      text: "Daemon Max · " + root.maxAmount + " sat · point-in-time"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Row {
      visible: root.inputVisible
      width: parent.width
      spacing: Style.spacing.controlGap

      Button {
        width: (parent.width - parent.spacing) / 2
        text: "Max"
        iconText: "󰾅"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.selectedMintUrl !== "" && root.commandsAvailable
        opacity: enabled ? 1 : 0.5
        onClicked: root.useMax()
      }

      Button {
        width: (parent.width - parent.spacing) / 2
        text: "Review Send"
        iconText: "󰄬"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.prepareEnabled
        opacity: enabled ? 1 : 0.5
        onClicked: root.prepare()
      }
    }

    Button {
      visible: root.viewState === "review"
      text: "Confirm Send"
      iconText: "󰄬"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.confirmEnabled
      opacity: enabled ? 1 : 0.5
      onClicked: root.confirm()
    }

    Text {
      visible: ["pending", "error"].indexOf(root.viewState) !== -1
        && root.error !== ""
      width: parent.width
      text: root.error
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Button {
      visible: root.viewState === "pending"
        || (root.viewState === "error" && root.service
          && ["result_not_available", "mint_unavailable", "reclaim_inconclusive"]
            .indexOf(String(root.service.sendErrorCode || "")) !== -1)
      text: "Check Pending Send"
      iconText: "󰑐"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.retryPending()
    }

    Button {
      visible: root.refreshedMaxAvailable
      text: "Use refreshed Max · " + root.maxAmount + " sat"
      iconText: "󰾅"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.useRefreshedMax()
    }

    Text {
      visible: root.viewState === "result"
      width: parent.width
      text: "Outgoing ecash is ready. Copy it explicitly and send it through your chosen channel."
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
    }

    Button {
      visible: root.viewState === "result"
      text: root.clipboardWrites > 0 ? "Copy again" : "Copy Cashu token"
      iconText: "󰆏"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.copyAvailable
      opacity: enabled ? 1 : 0.5
      onClicked: root.copyToken()
    }

    Button {
      visible: root.reclaimAvailable
        && ["result", "pending", "error"].indexOf(root.viewState) !== -1
      text: "Attempt Reclaim"
      iconText: "󰑓"
      foreground: root.urgent
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.beginReclaim()
    }

    Column {
      visible: root.viewState === "reclaim-warning"
      width: parent.width
      spacing: Style.spacing.labelGap

      Text {
        width: parent.width
        text: root.reclaimWarning
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Row {
        width: parent.width
        spacing: Style.spacing.controlGap

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Keep Pending"
          iconText: "󰅖"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.reclaimWarningVisible = false
        }

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Confirm Reclaim"
          iconText: "󰑓"
          foreground: root.urgent
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.confirmReclaim()
        }
      }
    }

    Text {
      visible: root.viewState === "reclaimed"
      width: parent.width
      text: "Reclaim succeeded. The reserved ecash is spendable again."
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
    }

    Button {
      visible: ["result", "pending", "reclaimed"].indexOf(root.viewState) !== -1
      text: root.viewState === "pending" ? "Keep Pending" : "Done"
      iconText: "󰄬"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.done()
    }

    Button {
      visible: root.viewState === "entry" || root.viewState === "review"
        || root.viewState === "error"
      text: root.viewState === "error" ? "Back"
        : root.viewState === "review" ? "Back and release reservation" : "Cancel"
      iconText: root.viewState === "error" ? "󰁍" : "󰅖"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.cancel()
    }
  }
}
