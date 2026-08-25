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
  property string outgoingToken: ""
  property int clipboardWrites: 0
  property bool reclaimWarningVisible: false
  property bool pendingDetailMode: false
  property bool pendingDetailFocused: false
  property string pendingOperationId: ""
  property string pendingAmount: ""
  property int pendingPresentationGeneration: 0
  property bool pendingTokenRevealed: false
  readonly property var pendingAction: service && pendingOperationId
    && typeof service.pendingSendAction === "function"
    ? service.pendingSendAction(pendingOperationId) : ({
      state: "idle", errorCode: "", error: "", terminalState: "", amount: ""
    })
  readonly property string pendingActionState: String(pendingAction.state || "idle")
  readonly property string pendingErrorCode: String(pendingAction.errorCode || "")
  readonly property string pendingError: String(pendingAction.error || "")
  readonly property string pendingTerminalState: String(pendingAction.terminalState || "")
  readonly property var pendingCanonicalOperation: service && pendingOperationId
    && typeof service.canonicalSendOperation === "function"
    ? service.canonicalSendOperation(pendingOperationId) : null
  readonly property bool pendingCanonical: pendingCanonicalOperation
    && String(pendingCanonicalOperation.state || "") === "pending"
  readonly property bool pendingBusy: ["copying", "revealing", "refreshing", "reclaiming"]
    .indexOf(pendingActionState) !== -1
  readonly property bool pendingCommandsAvailable: service
    && service.sendCommandsAvailable !== false && !service.sendCommandRequest
    && !service.sendResultReconciling && service.sendReconcileRequests.length === 0
  readonly property bool pendingResultAvailable: pendingDetailFocused
    && pendingCanonical && pendingCommandsAvailable && !pendingBusy
  readonly property bool pendingReclaimAvailable: pendingResultAvailable
  readonly property string reclaimWarning: pendingDetailMode
    ? "Reclaim " + pendingAmount + " sat from this exact Pending Send? Reclaim races recipient redemption; the recipient can still win while cocod checks the Mint."
    : "Reclaim may race with recipient redemption. The recipient can still win while cocod checks the Mint."

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
  readonly property var prepared: service ? service.sendPreparedOperation : null
  readonly property var reviewBalance: service && prepared
    && typeof service.sendBalanceForMint === "function"
    ? service.sendBalanceForMint(prepared.mintUrl) : null
  readonly property string error: service ? String(service.sendError || "") : ""
  readonly property bool ambiguousPreparation: service
    && !!service.sendAmbiguousCreation
  readonly property bool commandsAvailable: service
    && service.sendCommandsAvailable !== false
  readonly property bool prepareEnabled: viewState === "entry" && amountValid
    && selectedMintUrl !== "" && commandsAvailable
  readonly property bool confirmEnabled: viewState === "review" && commandsAvailable
  readonly property bool copyAvailable: viewState === "result" && outgoingToken !== ""
  readonly property bool reclaimAvailable: service
    && service.sendCanReclaim === true
    && ["result", "pending", "error"].indexOf(sendState) !== -1

  implicitHeight: pendingDetailMode ? pendingContent.implicitHeight : content.implicitHeight
  visible: pendingDetailMode ? pendingDetailFocused : viewState !== "closed"

  function updateMintSelection() {
    var selectedStillEligible = false
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
    writeOutgoingTokenToClipboard()
    return true
  }

  function writeOutgoingTokenToClipboard() {
    Quickshell.clipboardText = outgoingToken
    clipboardWrites++
  }

  function clearPendingToken() {
    outgoingToken = ""
    pendingTokenRevealed = false
    reclaimWarningVisible = false
  }

  function focusPendingDetail(operationId, amount) {
    if (!pendingDetailMode) return false
    pendingPresentationGeneration++
    clearPendingToken()
    pendingOperationId = String(operationId || "")
    pendingAmount = String(amount || "")
    pendingDetailFocused = pendingOperationId !== ""
    return pendingDetailFocused
  }

  function leavePendingDetail() {
    pendingPresentationGeneration++
    clearPendingToken()
    pendingDetailFocused = false
    pendingOperationId = ""
    pendingAmount = ""
  }

  function requestPendingResult(intent) {
    var requestedIntent = String(intent || "")
    if (!pendingResultAvailable || ["copy", "reveal"].indexOf(requestedIntent) === -1
        || !service || typeof service.requestActivePendingSendResult !== "function")
      return false
    pendingPresentationGeneration++
    clearPendingToken()
    return service.requestActivePendingSendResult(pendingOperationId,
      pendingPresentationGeneration, requestedIntent)
  }

  function copyPendingToken() {
    return requestPendingResult("copy")
  }

  function revealPendingToken() {
    return requestPendingResult("reveal")
  }

  function hidePendingToken() {
    if (!pendingTokenRevealed) return false
    pendingPresentationGeneration++
    clearPendingToken()
    return true
  }

  function refreshPending() {
    if (!pendingResultAvailable || !service
        || typeof service.refreshActivePendingSend !== "function") return false
    pendingPresentationGeneration++
    clearPendingToken()
    return service.refreshActivePendingSend(pendingOperationId)
  }

  function beginActivePendingReclaim() {
    if (!pendingReclaimAvailable) return false
    pendingPresentationGeneration++
    clearPendingToken()
    reclaimWarningVisible = true
    return true
  }

  function confirmActivePendingReclaim() {
    if (!reclaimWarningVisible || !pendingCanonical || !service
        || typeof service.reclaimActivePendingSend !== "function") return false
    reclaimWarningVisible = false
    outgoingToken = ""
    return service.reclaimActivePendingSend(pendingOperationId)
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
    if (ambiguousPreparation && service
        && typeof service.retryAmbiguousSendCreation === "function")
      return service.retryAmbiguousSendCreation()
    if (!service || !service.sendPendingOperation
        || typeof service.retrievePendingSendResult !== "function") return false
    return service.retrievePendingSendResult(service.sendPendingOperation.id)
  }

  onMintOptionsChanged: {
    if (viewState === "entry") updateMintSelection()
  }
  onViewStateChanged: {
    if (pendingDetailMode) return
    if (viewState === "entry") updateMintSelection()
    if (["result", "reclaim-warning"].indexOf(viewState) === -1)
      outgoingToken = ""
  }
  onPendingActionStateChanged: {
    if (pendingDetailMode && pendingActionState !== "idle") clearPendingToken()
  }
  onInputVisibleChanged: {
    if (!inputVisible) amountInput.focus = false
  }
  Connections {
    target: root.service
    ignoreUnknownSignals: true

    function onSendExecuted(token) {
      if (root.pendingDetailMode) return
      if (!root.opened || root.viewState !== "result") return
      root.outgoingToken = String(token || "")
    }

    function onPendingSendResultDelivered(operationId, presentationGeneration,
        intent, token) {
      if (!root.pendingDetailMode || !root.pendingDetailFocused
          || String(operationId || "") !== root.pendingOperationId
          || presentationGeneration !== root.pendingPresentationGeneration) return
      var value = String(token || "")
      if (String(intent || "") === "copy") {
        root.outgoingToken = value
        root.writeOutgoingTokenToClipboard()
        root.outgoingToken = ""
        root.pendingTokenRevealed = false
      } else if (String(intent || "") === "reveal") {
        root.outgoingToken = value
        root.pendingTokenRevealed = value !== ""
      }
      value = ""
    }

    function onSendPresentationInvalidated() {
      if (root.pendingDetailMode) root.pendingPresentationGeneration++
      root.clearPendingToken()
    }

    function onConnectionStateChanged() {
      if (!root.pendingDetailMode || !root.service
          || root.service.connectionState === "connected") return
      root.pendingPresentationGeneration++
      root.clearPendingToken()
    }
  }

  Column {
    id: content
    visible: !root.pendingDetailMode
    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader {
      text: "SEND ECASH"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      text: "Choose a Trusted Mint and enter a whole sat amount. cocod calculates fees and selects proofs when it prepares the Send."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      visible: ["preparing", "cancelling", "executing",
        "recovering-result", "reclaiming"]
        .indexOf(root.viewState) !== -1
      width: parent.width
      text: root.viewState === "preparing" ? "Preparing Send and reserving ecash…"
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

    Button {
      visible: root.inputVisible
      width: parent.width
      text: "Review Send"
      iconText: "󰄬"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.prepareEnabled
      opacity: enabled ? 1 : 0.5
      onClicked: root.prepare()
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
          && (!!root.service.sendPendingOperation || root.ambiguousPreparation))
      text: root.ambiguousPreparation ? "Retry preparation" : "Check Pending Send"
      iconText: "󰑐"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.retryPending()
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
        || root.viewState === "error" || ["preparing", "cancelling", "executing",
          "recovering-result", "reclaiming"].indexOf(root.viewState) !== -1
      text: root.viewState === "entry" ? "Cancel"
        : root.viewState === "review" ? "Cancel Prepared Send" : "Back"
      iconText: root.viewState === "error" ? "󰁍" : "󰅖"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.cancel()
    }
  }

  Column {
    id: pendingContent
    visible: root.pendingDetailMode && root.pendingDetailFocused
    width: parent.width
    spacing: Style.space(10)

    Text {
      visible: root.pendingBusy
      width: parent.width
      text: root.pendingActionState === "copying" ? "Retrieving this Send for Copy…"
        : root.pendingActionState === "revealing" ? "Retrieving this Send for Reveal…"
        : root.pendingActionState === "refreshing" ? "Refreshing this exact Pending Send…"
        : "Attempting Reclaim with cocod…"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Text {
      visible: root.pendingError !== "" && root.pendingTerminalState === ""
      width: parent.width
      text: root.pendingError
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      visible: root.pendingTokenRevealed
      width: parent.width
      text: root.outgoingToken
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WrapAnywhere
    }

    Button {
      visible: root.pendingTokenRevealed
      width: parent.width
      text: "Hide Cashu token"
      iconText: "󰈉"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: root.hidePendingToken()
    }

    Row {
      visible: root.pendingCanonical && !root.reclaimWarningVisible
        && root.pendingTerminalState === ""
      width: parent.width
      spacing: Style.spacing.controlGap

      Button {
        width: (parent.width - parent.spacing) / 2
        text: "Copy token"
        iconText: "󰆏"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.pendingResultAvailable
        opacity: enabled ? 1 : 0.5
        onClicked: root.copyPendingToken()
      }

      Button {
        width: (parent.width - parent.spacing) / 2
        text: "Reveal token"
        iconText: "󰈈"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.pendingResultAvailable
        opacity: enabled ? 1 : 0.5
        onClicked: root.revealPendingToken()
      }
    }

    Button {
      visible: root.pendingCanonical && !root.reclaimWarningVisible
        && root.pendingTerminalState === ""
      width: parent.width
      text: "Refresh Pending Send"
      iconText: "󰑐"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.pendingResultAvailable
      opacity: enabled ? 1 : 0.5
      onClicked: root.refreshPending()
    }

    Button {
      visible: root.pendingCanonical && !root.reclaimWarningVisible
        && root.pendingTerminalState === ""
      width: parent.width
      text: "Attempt Reclaim"
      iconText: "󰑓"
      foreground: root.urgent
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.pendingReclaimAvailable
      opacity: enabled ? 1 : 0.5
      onClicked: root.beginActivePendingReclaim()
    }

    Column {
      visible: root.reclaimWarningVisible
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
          enabled: root.pendingReclaimAvailable
          opacity: enabled ? 1 : 0.5
          onClicked: root.confirmActivePendingReclaim()
        }
      }
    }

    Text {
      visible: root.pendingTerminalState !== ""
      width: parent.width
      text: root.pendingTerminalState === "reclaimed"
        ? "Reclaim succeeded. The reserved ecash is spendable again."
        : root.pendingTerminalState === "recipient_won"
          ? "The recipient redeemed this Send before Reclaim completed."
          : root.pendingTerminalState === "completed"
            ? "This Send reached a terminal cocod outcome. Return to Active Sends to acknowledge the result."
            : root.pendingError
      color: root.pendingTerminalState === "reclaimed"
        ? root.foreground : root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }
}
