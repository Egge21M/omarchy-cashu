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
  property string recoveryViewState: "closed"
  property string recoveryPhrase: ""
  property string recoveryError: ""
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
    clearRecoveryPhrase()
    receiveFlow.panelClosed()
    opened = false
  }

  function dismiss() {
    clearRecoveryPhrase()
    receiveFlow.panelClosed()
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function amountText(value) {
    var digits = String(value === undefined || value === null ? "0" : value)
    if (!/^(0|[1-9][0-9]*)$/.test(digits)) digits = "0"
    var firstGroup = digits.length % 3
    if (firstGroup === 0) firstGroup = 3
    var formatted = digits.slice(0, firstGroup)
    for (var index = firstGroup; index < digits.length; index += 3)
      formatted += "," + digits.slice(index, index + 3)
    return formatted + " " + (stateOwner ? stateOwner.unit : "sat")
  }

  function smokeCreateWallet() {
    if (!createWalletButton.visible || !createWalletButton.enabled) return "disabled"
    createWalletButton.clicked()
    return "ok"
  }

  function openRecoveryPhrase() {
    if (!viewRecoveryPhraseButton.visible || recoveryViewState !== "closed") return false
    receiveFlow.close()
    recoveryPhrase = ""
    recoveryError = ""
    recoveryViewState = "warning"
    return true
  }

  function confirmRecoveryPhrase() {
    if (recoveryViewState !== "warning" || !stateOwner) return false
    recoveryPhrase = ""
    recoveryError = ""
    recoveryViewState = "requesting"
    if (!stateOwner.revealRecoveryPhrase()) {
      recoveryViewState = "warning"
      recoveryError = "Recovery Phrase could not be revealed"
      return false
    }
    return true
  }

  function clearRecoveryPhrase() {
    recoveryPhrase = ""
    recoveryError = ""
    recoveryViewState = "closed"
    if (stateOwner && typeof stateOwner.cancelRecoveryPhraseReveal === "function")
      stateOwner.cancelRecoveryPhraseReveal()
  }

  function smokeOpenRecoveryPhrase() {
    if (!viewRecoveryPhraseButton.visible) return "disabled"
    viewRecoveryPhraseButton.clicked()
    return "ok"
  }

  function smokeConfirmRecoveryPhrase() {
    if (!confirmRecoveryPhraseButton.visible || !confirmRecoveryPhraseButton.enabled)
      return "disabled"
    confirmRecoveryPhraseButton.clicked()
    return "ok"
  }

  function smokeLeaveRecoveryPhrase() {
    if (recoveryViewState === "warning" || recoveryViewState === "requesting") {
      cancelRecoveryPhraseButton.clicked()
      return "ok"
    }
    if (recoveryViewState === "revealed") {
      backRecoveryPhraseButton.clicked()
      return "ok"
    }
    return "disabled"
  }

  function smokeOpenReceive() {
    if (!receiveButton.visible || !receiveButton.enabled) return "disabled"
    receiveButton.clicked()
    return "ok"
  }

  function smokePasteReceive() {
    return receiveFlow.paste() ? "ok" : "disabled"
  }

  function smokePreviewReceive() {
    return receiveFlow.review() ? "ok" : "disabled"
  }

  function smokeApproveReceiveMint() {
    return receiveFlow.toggleMintApproval() ? "ok" : "disabled"
  }

  function smokeConfirmReceive() {
    return receiveFlow.confirm() ? "ok" : "disabled"
  }

  function smokeCancelReceive() {
    if (receiveFlow.viewState === "closed") return "disabled"
    receiveFlow.close()
    return "ok"
  }

  function smokeSnapshot() {
    return JSON.stringify({
      opened: opened,
      anchored: !!anchorItem,
      requestedScreenName: requestedScreenName,
      anchorScreenName: widgetScreenName(hostWidget),
      refreshCount: stateOwner ? stateOwner.refreshCount : 0,
      walletState: stateOwner ? stateOwner.walletState : "unavailable",
      connectionState: stateOwner ? stateOwner.connectionState : "missing",
      compatibilityState: stateOwner ? stateOwner.compatibilityState : "unknown",
      balancesAvailable: stateOwner ? stateOwner.balancesAvailable : false,
      spendableBalance: stateOwner ? stateOwner.spendableBalance : "0",
      reservedBalance: stateOwner ? stateOwner.reservedBalance : "0",
      spendableText: spendableValue.text,
      reservedText: reservedValue.text,
      retryVisible: retryConnectionButton.visible,
      retryLabel: retryConnectionButton.text,
      createVisible: createWalletButton.visible,
      createEnabled: createWalletButton.enabled,
      createLabel: createWalletButton.text,
      recoveryEntryVisible: viewRecoveryPhraseButton.visible,
      recoveryViewState: recoveryViewState,
      recoveryWarningVisible: recoveryWarning.visible,
      recoveryConfirmVisible: confirmRecoveryPhraseButton.visible,
      recoveryPhraseVisible: recoveryPhraseText.visible,
      receiveViewState: receiveFlow.viewState,
      receiveInputVisible: receiveFlow.inputVisible,
      receiveTextPresent: receiveFlow.textPresent,
      receivePasteVisible: receiveFlow.pasteVisible,
      receiveClipboardReads: receiveFlow.clipboardReads,
      receivePreviewAmount: receiveFlow.preview ? receiveFlow.preview.amount : "",
      receivePreviewFee: receiveFlow.preview ? receiveFlow.preview.fee : "",
      receivePreviewNetAmount: receiveFlow.preview ? receiveFlow.preview.netAmount : "",
      receivePreviewUnit: receiveFlow.preview ? receiveFlow.preview.unit : "",
      receivePreviewMint: receiveFlow.preview ? receiveFlow.preview.mintUrl : "",
      receiveMintTrusted: receiveFlow.preview ? receiveFlow.preview.trusted : false,
      receiveApprovalVisible: receiveFlow.approvalVisible,
      receiveMintApproved: receiveFlow.mintApproved,
      receiveConfirmEnabled: receiveFlow.confirmEnabled,
      receiveError: receiveFlow.error,
      keyCatcherBlocked: keyCatcher.blocked,
      activeTransferCount: stateOwner ? stateOwner.activeTransfers.length : 0,
      setupTitle: stateOwner ? stateOwner.setupTitle : "cocod is not available"
    })
  }

  onOpenedChanged: {
    if (!opened) {
      clearRecoveryPhrase()
      receiveFlow.panelClosed()
    }
  }

  Component.onDestruction: clearRecoveryPhrase()

  Connections {
    target: root.stateOwner
    ignoreUnknownSignals: true

    function onRecoveryPhraseRevealed(phrase) {
      if (!root.opened || root.recoveryViewState !== "requesting") return
      root.recoveryPhrase = phrase
      root.recoveryViewState = "revealed"
    }

    function onRecoveryPhraseRevealFailed(detail) {
      if (root.recoveryViewState !== "requesting") return
      root.recoveryPhrase = ""
      root.recoveryError = detail
      root.recoveryViewState = "warning"
    }

    function onWalletStateChanged() {
      if (!root.stateOwner || root.stateOwner.walletState !== "unlocked") {
        root.clearRecoveryPhrase()
        receiveFlow.panelClosed()
      }
    }
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
      blocked: receiveFlow.inputFocused
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
            detail: root.stateOwner
              ? root.stateOwner.connectionState.toUpperCase() : "MISSING"
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
            visible: root.stateOwner && root.stateOwner.walletState === "unlocked"
              && receiveFlow.viewState === "closed"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "RECOVERY PHRASE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.recoveryViewState === "closed"
              width: parent.width
              text: "Reveal the Recovery Phrase only when you are ready to store it privately."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              id: viewRecoveryPhraseButton
              visible: root.stateOwner
                && root.stateOwner.walletState === "unlocked"
                && root.recoveryViewState === "closed"
              text: "View Recovery Phrase"
              iconText: "󰌆"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openRecoveryPhrase()
            }

            Text {
              id: recoveryWarning
              visible: root.recoveryViewState === "warning"
                || root.recoveryViewState === "requesting"
              width: parent.width
              text: "Anyone with your Recovery Phrase can take your ecash. Make sure nobody can see your screen and store the words somewhere private."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.WordWrap
            }

            Text {
              visible: recoveryWarning.visible && root.recoveryError !== ""
              width: parent.width
              text: root.recoveryError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              visible: recoveryWarning.visible
              width: parent.width
              spacing: Style.spacing.controlGap

              Button {
                id: confirmRecoveryPhraseButton
                width: (parent.width - parent.spacing) / 2
                visible: recoveryWarning.visible
                enabled: root.recoveryViewState === "warning"
                text: root.recoveryViewState === "requesting"
                  ? "Revealing…" : "I understand, reveal"
                iconText: "󰄬"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.confirmRecoveryPhrase()
              }

              Button {
                id: cancelRecoveryPhraseButton
                width: (parent.width - parent.spacing) / 2
                text: "Cancel"
                iconText: "󰅖"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.clearRecoveryPhrase()
              }
            }

            Text {
              id: recoveryPhraseText
              visible: root.recoveryViewState === "revealed"
                && root.recoveryPhrase !== ""
              width: parent.width
              text: visible ? root.recoveryPhrase : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            Button {
              id: backRecoveryPhraseButton
              visible: root.recoveryViewState === "revealed"
              text: "Back"
              iconText: "󰁍"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.clearRecoveryPhrase()
            }
          }

          PanelSeparator {
            visible: root.stateOwner && root.stateOwner.walletState === "unlocked"
              && receiveFlow.viewState === "closed"
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
              visible: receiveFlow.viewState === "closed"
              width: parent.width
              spacing: Style.spacing.rowGap

              Text {
                text: root.stateOwner && root.stateOwner.connectionState === "connected"
                  ? "󰄬" : "󰋗"
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
                  text: root.stateOwner
                    ? root.stateOwner.setupTitle : "cocod is not available"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  width: parent.width
                  text: root.stateOwner
                    ? root.stateOwner.setupDetail
                    : "Start cocod, then retry the connection."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }
            }

            Button {
              id: retryConnectionButton
              visible: root.stateOwner
                && root.stateOwner.connectionState !== "connected"
              text: root.stateOwner
                && root.stateOwner.compatibilityState === "incompatible"
                ? "Check again" : "Retry connection"
              iconText: "󰑐"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.stateOwner.retryConnection()
            }
            Button {
              id: createWalletButton
              visible: root.stateOwner
                && root.stateOwner.connectionState === "connected"
                && root.stateOwner.compatibilityState === "compatible"
                && root.stateOwner.walletState === "uninitialized"
              enabled: visible && !root.stateOwner.creating
              text: root.stateOwner && root.stateOwner.creating
                ? "Creating Wallet…" : "Create Wallet"
              iconText: "󰆦"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.stateOwner.createWallet()
            }

            Text {
              visible: createWalletButton.visible && root.stateOwner
                && root.stateOwner.createError !== ""
              width: parent.width
              text: root.stateOwner ? root.stateOwner.createError : ""
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
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
                  id: spendableValue
                  text: root.stateOwner && root.stateOwner.balancesAvailable
                    ? root.amountText(root.stateOwner.spendableBalance) : "Unavailable"
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
                  id: reservedValue
                  text: root.stateOwner && root.stateOwner.balancesAvailable
                    ? root.amountText(root.stateOwner.reservedBalance) : "Unavailable"
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
                id: receiveButton
                width: (parent.width - parent.spacing) / 2
                text: "Receive"
                iconText: "󰑐"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: root.stateOwner
                  && root.stateOwner.walletState === "unlocked"
                  && root.recoveryViewState === "closed"
                  && receiveFlow.viewState === "closed"
                opacity: enabled ? 1 : 0.5
                onClicked: {
                  root.clearRecoveryPhrase()
                  receiveFlow.open()
                }
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
              visible: receiveFlow.viewState === "closed"
              width: parent.width
              text: "Send remains unavailable in this slice."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            ReceiveFlow {
              id: receiveFlow
              width: parent.width
              service: root.stateOwner
              foreground: root.foreground
              urgent: root.urgent
              dim: root.dim
              fontFamily: root.fontFamily
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
                    ? root.activeTransfer.detail : ""
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
