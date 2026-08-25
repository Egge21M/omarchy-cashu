import QtQuick
import Quickshell
import Quickshell.Io

// The Shell Adapter is the only transport-owning module. Bar and panel callers
// consume the domain properties below and never see URLs, credentials, XHR,
// SSE frames, retry timers, or canonical-resource composition.
Item {
  id: root

  signal recoveryPhraseRevealed(string phrase)
  signal recoveryPhraseRevealFailed(string detail)
  signal sendExecuted(string token)

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.egge21m.omarchy-cashu"
  readonly property string diagnosticsTarget: pluginId + ".state"
  property string daemonBaseUrl: {
    var configured = Quickshell.env("OMARCHY_CASHU_DAEMON_URL")
    return configured ? String(configured).replace(/\/$/, "") : "http://127.0.0.1:62626"
  }
  readonly property bool daemonUrlAllowed: isLoopbackBaseUrl(daemonBaseUrl)
  readonly property string stateRoot: {
    var configured = String(Quickshell.env("COCOD_STATE_DIR") || "")
    if (configured.charAt(0) === "/") return configured.replace(/\/$/, "")
    return String(Quickshell.env("HOME") || "") + "/.cocod"
  }
  readonly property string credentialPath: stateRoot + "/credentials/current/client"
  readonly property var requiredOpenApiPaths: [
    "/v1/status",
    "/v1/balances",
    "/v1/events",
    "/v1/mints",
    "/v1/operations/receive",
    "/v1/operations/receive/{operationId}",
    "/v1/operations/receive/prepared",
    "/v1/operations/receive/in-flight",
    "/v1/operations/receive/{operationId}/execute",
    "/v1/operations/receive/{operationId}/cancel",
    "/v1/operations/receive/{operationId}/refresh",
    "/v1/operations/send",
    "/v1/operations/send/{operationId}",
    "/v1/operations/send/prepared",
    "/v1/operations/send/in-flight",
    "/v1/operations/send/{operationId}/execute",
    "/v1/operations/send/{operationId}/result",
    "/v1/operations/send/{operationId}/cancel",
    "/v1/operations/send/{operationId}/refresh",
    "/v1/operations/send/{operationId}/reclaim",
    "/v1/admin/wallet/initialize",
    "/v1/admin/wallet/recovery-material"
  ]

  property int reconnectBaseMs: 250
  property int reconnectMaximumMs: 4000
  property int streamRotationMs: 30000
  property int streamMaximumCharacters: 32768
  property int heartbeatTimeoutMs: 20000

  property var openApiResource: ({})
  property var statusResource: ({
    daemon: { version: "", interfaceVersion: "" },
    wallet: null,
    seedAccess: null,
    cocoSession: { state: "stopped", startedAt: null, lastFailure: null }
  })
  property var balancesResource: ({ items: [] })
  property var mintsResource: ({ items: [] })
  property var receiveOperations: []
  property var sendOperations: []
  property int refreshCount: 0

  property string connectionState: "connecting"
  property string compatibilityState: "unknown"
  property string connectionDetail: "Connecting to cocod on loopback"
  property string lastErrorCode: ""
  property int retryAttempt: 0
  property int retryDelayMs: 0
  property int serverRetryMs: 3000
  property int streamCharacters: 0
  property int heartbeatCount: 0
  property int rotationCount: 0
  property int reconnectCount: 0

  property int fullFetchToken: 0
  property bool fullFetchInProgress: false
  property string deferredReconcileReason: ""
  property bool queuedSendInvalidation: false
  property bool queuedBalanceInvalidation: false
  property var queuedReceiveInvalidations: ({})
  property var canonicalRequests: []
  property var balanceRequest: null
  property var mintRequest: null
  property var receiveRequests: []
  property var sendRequests: []
  property var sendLookupRequestsById: ({})
  property var queuedSendOperationInvalidations: ({})
  property var streamRequest: null
  property int streamOffset: 0
  property string streamBuffer: ""
  property var createRequest: null
  property bool creating: false
  property string createError: ""
  property int createSettlementAttempts: 0
  property int createSettlementMaximumAttempts: 80
  property var recoveryRevealRequest: null
  property var receiveRequest: null
  property var receiveReconcileRequests: []
  property int receiveReconcileToken: 0
  property int receiveResourceGeneration: 0
  property var receiveLookupTokens: ({})
  property string receiveState: "idle"
  property string receiveError: ""
  property string receiveOperationId: ""
  property bool receiveCancelOnPrepared: false
  property var receiveAmbiguousCreation: null
  readonly property var receivePreparedOperation: canonicalPreparedReceive(
    receiveOperationId)
  property var receiveRecoveries: ({})
  property string receiveRecoveryFocusId: ""
  readonly property var receiveRecovery: receiveRecoveryProjection(
    receiveRecoveryFocusId)
  readonly property string receiveRecoveryState: String(receiveRecovery.state || "idle")
  readonly property string receiveRecoveryOperationId: String(
    receiveRecovery.operationId || "")
  readonly property string receiveRecoveryError: String(receiveRecovery.error || "")
  property var sendCommandRequest: null
  property var sendReconcileRequests: []
  property string sendState: "idle"
  property string sendError: ""
  property string sendErrorCode: ""
  property string sendOperationId: ""
  property bool sendCancelOnPrepared: false
  property var sendAmbiguousCreation: null
  property bool sendResultReconciling: false
  property bool sendDismissAfterResult: false
  readonly property var sendFocusedOperation: canonicalSendOperation(sendOperationId)
  readonly property var sendPreparedOperation: canonicalPreparedSend(sendOperationId)
  readonly property var sendPendingOperation: sendFocusedOperation
    && String(sendFocusedOperation.state || "") === "pending"
    ? sendFocusedOperation : null
  readonly property bool sendCanCancelReservation: sendOperationId !== ""
    && ["review", "error"].indexOf(sendState) !== -1
    && !sendCommandRequest
    && (!!sendPreparedOperation || (!sendPendingOperation && sendState === "error"))
  readonly property bool sendCanReclaim: !!sendPendingOperation
    && ["result", "pending", "error"].indexOf(sendState) !== -1
    && !sendCommandRequest && !sendResultReconciling
    && sendReconcileRequests.length === 0
  readonly property bool sendCommandsAvailable: !fullFetchInProgress
    && connectionState === "connected" && compatibilityState === "compatible"
    && walletState === "unlocked" && sendAvailable
  readonly property bool receiveCommandsAvailable: !fullFetchInProgress
    && connectionState === "connected" && compatibilityState === "compatible"
    && walletState === "unlocked" && receiveAvailable
  readonly property bool receiveAvailable: openApiPathAvailable("/v1/operations/receive")
  readonly property bool sendAvailable: openApiPathAvailable("/v1/operations/send")

  readonly property bool fixtureBacked: false
  readonly property string walletState: connectionState === "connected"
    ? projectWalletState(statusResource) : "unavailable"
  readonly property string walletStateLabel: stateLabel(walletState)
  readonly property string walletStateDetail: connectionState === "connected"
    ? lifecycleDetail(statusResource) : connectionDetail
  readonly property string walletStateGlyph: stateGlyph(walletState)
  readonly property string barStateLabel: {
    if (compatibilityState === "incompatible") return "Update required"
    if (connectionState === "missing") return "Setup required"
    if (connectionState === "unavailable") return "Unavailable"
    if (connectionState === "error") return "Connection error"
    if (connectionState === "connecting") return "Connecting"
    if (connectionState === "reconnecting") return "Reconnecting"
    return walletStateLabel
  }
  readonly property string barStateGlyph: {
    if (compatibilityState === "incompatible") return "󰚰"
    if (connectionState === "missing") return "󰋗"
    if (connectionState === "error") return "󰅚"
    if (connectionState !== "connected") return "󰅙"
    return walletStateGlyph
  }
  readonly property var balanceProjection: composeSatBalances(balancesResource)
  readonly property bool balancesAvailable: connectionState === "connected"
    && compatibilityState === "compatible"
    && (walletState === "uninitialized" || walletState === "unlocked")
  readonly property string spendableBalance: balancesAvailable
    ? balanceProjection.spendable : "0"
  readonly property string reservedBalance: balancesAvailable
    ? balanceProjection.reserved : "0"
  readonly property string unit: "sat"
  readonly property var activeTransfers: composeActiveTransfers(
    receiveOperations, sendOperations, receiveRecoveries)
  readonly property var trustedMints: trustedKnownMints(mintsResource)
  readonly property bool hasActiveTransfers: activeTransfers.length > 0
  readonly property bool needsAttention: compatibilityState === "incompatible"
    || connectionState !== "connected"
    || ["uninitialized", "locked", "error", "unavailable"].indexOf(walletState) !== -1
  readonly property bool barActive: hasActiveTransfers
  readonly property bool barAttention: needsAttention
  readonly property string setupTitle: setupView().title
  readonly property string setupDetail: setupView().detail

  function stateLabel(state) {
    var labels = {
      unavailable: "Unavailable",
      uninitialized: "Not initialized",
      locked: "Locked",
      unlocked: "Unlocked",
      error: "Error"
    }
    return labels[state] || "Unknown"
  }

  function stateGlyph(state) {
    var glyphs = {
      unavailable: "󰅙",
      uninitialized: "󰦒",
      locked: "󰌾",
      unlocked: "󰖄",
      error: "󰅚"
    }
    return glyphs[state] || "󰘥"
  }

  function isLoopbackBaseUrl(value) {
    return /^http:\/\/(127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?$/.test(String(value || ""))
  }

  function clientCredential() {
    var value = String(credentialFile.text() || "")
    if (!/^[A-Za-z0-9_-]{43}\n$/.test(value)) return ""
    return value.slice(0, -1)
  }

  function setupView() {
    if (!daemonUrlAllowed) return {
      title: "Invalid cocod connection",
      detail: "Use an HTTP endpoint on 127.0.0.1, localhost, or ::1."
    }
    if (lastErrorCode === "credential_unavailable") return {
      title: "cocod credential is unavailable",
      detail: "Start cocod so it can provision the private Client Credential."
    }
    if (compatibilityState === "incompatible") return {
      title: "Incompatible cocod contract",
      detail: "Install a cocod version that exposes the required v1 OpenAPI resources."
    }
    if (connectionState === "missing") return {
      title: "cocod is not available",
      detail: "Start cocod on 127.0.0.1:62626."
    }
    if (connectionState === "unavailable") return {
      title: "cocod is temporarily unavailable",
      detail: "The Wallet Client will reconnect automatically."
    }
    if (connectionState === "error") return {
      title: "cocod returned an invalid response",
      detail: "Check the daemon and retry the connection."
    }
    if (connectionState === "connecting" || connectionState === "reconnecting") return {
      title: connectionState === "connecting" ? "Connecting to cocod" : "Reconnecting to cocod",
      detail: retryDelayMs > 0 ? "Next attempt in " + retryDelayMs + " ms."
        : "Fetching canonical Wallet resources."
    }
    return {
      title: "Connected to cocod",
      detail: "Live Wallet State · cocod interface v1"
    }
  }

  function snapshot() {
    return {
      apiVersion: String(openApiResource["x-cocod-interface-version"] || ""),
      receiveAvailable: receiveAvailable,
      sendAvailable: sendAvailable,
      daemonUrlAllowed: daemonUrlAllowed,
      refreshCount: refreshCount,
      fixtureBacked: fixtureBacked,
      walletState: walletState,
      walletStateLabel: walletStateLabel,
      walletStateDetail: walletStateDetail,
      barStateLabel: barStateLabel,
      balancesAvailable: balancesAvailable,
      spendableBalance: spendableBalance,
      reservedBalance: reservedBalance,
      unit: unit,
      activeTransfers: activeTransfers,
      trustedMintCount: trustedMints.length,
      receiveState: receiveState,
      receiveError: receiveError,
      receiveRecoveryState: receiveRecoveryState,
      receiveRecoveryOperationId: receiveRecoveryOperationId,
      receiveRecoveryError: receiveRecoveryError,
      receiveRecoveryMessage: receiveRecoveryMessage(),
      receiveRecoveries: receiveRecoveries,
      sendState: sendState,
      sendError: sendError,
      sendErrorCode: sendErrorCode,
      sendPreparedOperation: projectSendOperation(sendPreparedOperation),
      sendPendingOperation: projectSendOperation(sendPendingOperation),
      creating: creating,
      createError: createError,
      connectionState: connectionState,
      canonicalRefreshInProgress: fullFetchInProgress,
      compatibilityState: compatibilityState,
      connectionDetail: connectionDetail,
      lastErrorCode: lastErrorCode,
      setupTitle: setupTitle,
      setupDetail: setupDetail,
      barAttention: barAttention,
      barActive: barActive,
      retryAttempt: retryAttempt,
      retryDelayMs: retryDelayMs,
      heartbeatCount: heartbeatCount,
      rotationCount: rotationCount,
      streamRotationScheduled: rotationTimer.running,
      reconnectCount: reconnectCount,
      streamCharacters: streamCharacters
    }
  }

  function snapshotJson() {
    return JSON.stringify(snapshot())
  }

  function decimalString(value) {
    var text = String(value === undefined || value === null ? "" : value)
    return /^(0|[1-9][0-9]*)$/.test(text) ? text : ""
  }

  function addDecimalStrings(left, right) {
    var a = decimalString(left)
    var b = decimalString(right)
    if (!a || !b) return ""
    var i = a.length - 1
    var j = b.length - 1
    var carry = 0
    var result = ""
    while (i >= 0 || j >= 0 || carry > 0) {
      var digitA = i >= 0 ? a.charCodeAt(i) - 48 : 0
      var digitB = j >= 0 ? b.charCodeAt(j) - 48 : 0
      var sum = digitA + digitB + carry
      result = String(sum % 10) + result
      carry = Math.floor(sum / 10)
      i--
      j--
    }
    return result.replace(/^0+(?=[0-9])/, "")
  }

  function compareDecimalStrings(left, right) {
    var a = decimalString(left)
    var b = decimalString(right)
    if (!a || !b) return 0
    if (a.length !== b.length) return a.length < b.length ? -1 : 1
    if (a === b) return 0
    return a < b ? -1 : 1
  }

  function composeSatBalances(resource) {
    var spendable = "0"
    var reserved = "0"
    var items = resource && Array.isArray(resource.items) ? resource.items : []
    for (var i = 0; i < items.length; i++) {
      if (String(items[i].unit || "") !== "sat") continue
      spendable = addDecimalStrings(spendable, items[i].spendable)
      reserved = addDecimalStrings(reserved, items[i].reserved)
    }
    return { spendable: spendable || "0", reserved: reserved || "0" }
  }

  function trustedKnownMints(resource) {
    var result = []
    var items = resource && Array.isArray(resource.items) ? resource.items : []
    for (var i = 0; i < items.length; i++) if (items[i].trusted === true) result.push(items[i])
    return result
  }

  function isTrustedSendMint(mintUrl) {
    var selected = String(mintUrl || "")
    var known = mintsResource && Array.isArray(mintsResource.items)
      ? mintsResource.items : []
    for (var index = 0; index < known.length; index++)
      if (String(known[index].mintUrl || "") === selected)
        return known[index].trusted === true
    return false
  }

  function sendMintOptions(amount) {
    var requested = String(amount === undefined || amount === null ? "" : amount)
    var requireFunding = /^[1-9][0-9]*$/.test(requested)
    var trusted = ({})
    var known = mintsResource && Array.isArray(mintsResource.items)
      ? mintsResource.items : []
    for (var mintIndex = 0; mintIndex < known.length; mintIndex++)
      if (known[mintIndex].trusted === true)
        trusted[String(known[mintIndex].mintUrl || "")] = known[mintIndex]
    var balances = balancesResource && Array.isArray(balancesResource.items)
      ? balancesResource.items : []
    var result = []
    for (var balanceIndex = 0; balanceIndex < balances.length; balanceIndex++) {
      var balance = balances[balanceIndex]
      var mintUrl = String(balance.mintUrl || "")
      var spendable = decimalString(balance.spendable)
      if (String(balance.unit || "") !== "sat" || !trusted[mintUrl]
          || !spendable || spendable === "0") continue
      if (requireFunding && compareDecimalStrings(spendable, requested) < 0) continue
      result.push({
        mintUrl: mintUrl,
        name: String(trusted[mintUrl].name || mintUrl),
        spendable: spendable,
        reserved: String(balance.reserved || "0"),
        unit: "sat"
      })
    }
    return result
  }

  function sendBalanceForMint(mintUrl) {
    var selected = String(mintUrl || "")
    var balances = balancesResource && Array.isArray(balancesResource.items)
      ? balancesResource.items : []
    for (var index = 0; index < balances.length; index++)
      if (String(balances[index].mintUrl || "") === selected
          && String(balances[index].unit || "") === "sat") return {
        mintUrl: selected,
        unit: "sat",
        spendable: String(balances[index].spendable || "0"),
        reserved: String(balances[index].reserved || "0"),
        total: String(balances[index].total || "0")
      }
    return null
  }

  function canonicalSendOperation(operationId) {
    var selected = String(operationId || "")
    var operations = Array.isArray(sendOperations) ? sendOperations : []
    for (var index = 0; selected && index < operations.length; index++)
      if (String(operations[index].id || "") === selected)
        return operations[index]
    return null
  }

  function canonicalPreparedSend(operationId) {
    var operation = canonicalSendOperation(operationId)
    return operation && String(operation.state || "") === "prepared"
      ? operation : null
  }

  function firstCanonicalPreparedSend() {
    var operations = Array.isArray(sendOperations) ? sendOperations : []
    for (var index = 0; index < operations.length; index++)
      if (String(operations[index].state || "") === "prepared")
        return operations[index]
    return null
  }

  function firstCanonicalPendingSend() {
    var operations = Array.isArray(sendOperations) ? sendOperations : []
    for (var index = 0; index < operations.length; index++)
      if (String(operations[index].state || "") === "pending")
        return operations[index]
    return null
  }

  function reconcileFocusedPreparedSend() {
    if (!sendOperationId) return
    var operation = canonicalSendOperation(sendOperationId)
    if (operation && String(operation.state || "") === "pending") {
      if (sendState === "executing"
          || (sendState === "error" && sendErrorCode === "transport_unavailable")) {
        retrievePendingSendResult(sendOperationId)
        return
      }
      if (["result", "recovering-result", "pending", "reclaiming"]
          .indexOf(sendState) !== -1) return
      if (sendState === "error"
          && ["result_not_available", "coco_error", "operation_conflict"]
            .indexOf(sendErrorCode) !== -1) return
      sendOperationId = ""
      failSend("operation_conflict")
      return
    }
    var reconcilesCommandError = sendState === "error"
      && ["operation_not_found", "operation_conflict"].indexOf(sendErrorCode) !== -1
    if (operation && String(operation.state || "") === "prepared"
        && (sendState === "review" || reconcilesCommandError)) return
    if (sendState !== "review" && !reconcilesCommandError) return
    sendOperationId = ""
    failSend(operation ? "operation_conflict" : "operation_not_found")
  }

  function operationStateLabel(operation) {
    var labels = {
      prepared: operation.type === "receive" ? "Receive ready" : "Send ready",
      executing: operation.type === "receive" ? "Receiving" : "Sending",
      pending: "Pending Send",
      rolling_back: "Reclaiming"
    }
    return labels[String(operation.state || "")] || "Active Transfer"
  }

  function receiveRecoveryMessage() {
    return String(receiveRecovery.message || "")
  }

  function receiveRecoveryProjection(operationId) {
    var id = String(operationId || "")
    if (id && receiveRecoveries[id]) return receiveRecoveries[id]
    return {
      operationId: "",
      state: "idle",
      error: "",
      message: "",
      stateLabel: "",
      detail: "",
      severity: "none"
    }
  }

  function buildReceiveRecoveryProjection(operationId, state, error) {
    var messages = {
      recovering: "Recovering interrupted Receive",
      finalized: "Interrupted Receive completed",
      rolled_back: "Interrupted Receive was rolled back",
      unavailable: "Interrupted Receive is temporarily unavailable",
      failed: "Interrupted Receive needs attention"
    }
    var labels = {
      recovering: "Recovering Receive",
      unavailable: "Receive temporarily unavailable",
      failed: "Receive needs attention"
    }
    return {
      operationId: String(operationId || ""),
      state: String(state || "idle"),
      error: String(error || ""),
      message: messages[state] || "",
      stateLabel: labels[state] || "",
      detail: String(error || ""),
      severity: ["rolled_back", "failed"].indexOf(state) !== -1
        ? "error" : state === "unavailable" ? "warning" : "normal"
    }
  }

  function updateReceiveRecovery(operationId, state, error) {
    var id = String(operationId || "")
    if (!id) return
    var recoveries = ({})
    for (var key in receiveRecoveries) recoveries[key] = receiveRecoveries[key]
    recoveries[id] = buildReceiveRecoveryProjection(id, state, error)
    receiveRecoveries = recoveries
    receiveRecoveryFocusId = id
  }

  function composeActiveTransfers(receives, sends, recoveries) {
    var result = []
    var seen = ({})
    var values = (Array.isArray(receives) ? receives : [])
      .concat(Array.isArray(sends) ? sends : [])
    for (var i = 0; i < values.length; i++) {
      var operation = values[i]
      var id = String(operation.id || "")
      if (!id || seen[id]) continue
      seen[id] = true
      var recovery = operation.type === "receive" && recoveries
        ? recoveries[id] : null
      var recovering = recovery
        && ["recovering", "unavailable", "failed"].indexOf(recovery.state) !== -1
      result.push({
        id: id,
        type: String(operation.type || ""),
        state: String(operation.state || ""),
        stateLabel: recovering ? String(recovery.stateLabel)
          : operationStateLabel(operation),
        detail: recovering && recovery.detail
          ? String(recovery.detail) : String(operation.mintUrl || ""),
        amount: operationAmount(operation) || "0",
        unit: String(operation.unit || "sat")
      })
    }
    return result
  }

  function projectWalletState(status) {
    if (!status || status.wallet === null || status.wallet === undefined) return "uninitialized"
    var seedState = status.seedAccess ? String(status.seedAccess.state || "") : ""
    var sessionState = status.cocoSession ? String(status.cocoSession.state || "") : ""
    if (sessionState === "failed") return "error"
    if (seedState === "locked") return "locked"
    if (seedState === "available" && sessionState === "running") return "unlocked"
    return "unavailable"
  }

  function lifecycleDetail(status) {
    if (!status || !status.wallet) return "Create a Wallet Instance to get started"
    var sessionState = status.cocoSession ? String(status.cocoSession.state || "") : "unknown"
    if (status.seedAccess && status.seedAccess.state === "locked") return "Wallet Seed Access is locked"
    if (sessionState === "running") return "Coco Session running"
    if (sessionState === "failed") return "Coco Session requires a cocod restart"
    return "Coco Session " + sessionState
  }

  function containsSensitiveKey(value) {
    if (!value || typeof value !== "object") return false
    var forbidden = ["token", "proof", "secret", "mnemonic", "credential", "recoveryphrase"]
    for (var key in value) {
      var lowered = String(key).toLowerCase()
      for (var i = 0; i < forbidden.length; i++)
        if (lowered.indexOf(forbidden[i]) !== -1) return true
      if (containsSensitiveKey(value[key])) return true
    }
    return false
  }

  function openApiPathAvailable(path) {
    return !!(openApiResource && openApiResource.paths
      && typeof openApiResource.paths[String(path || "")] === "object"
    )
  }

  function isOpenApiShape(value) {
    if (!value || typeof value !== "object" || value.openapi !== "3.1.0"
        || String(value["x-cocod-interface-version"] || "") !== "1"
        || !value.paths || typeof value.paths !== "object") return false
    for (var i = 0; i < requiredOpenApiPaths.length; i++)
      if (!value.paths[requiredOpenApiPaths[i]]
          || typeof value.paths[requiredOpenApiPaths[i]] !== "object") return false
    return true
  }

  function isStatusShape(value) {
    if (!value || typeof value !== "object" || !value.daemon || !value.cocoSession) return false
    if (String(value.daemon.interfaceVersion || "") !== "1") return false
    var sessions = ["stopped", "starting", "running", "stopping", "failed"]
    if (sessions.indexOf(String(value.cocoSession.state || "")) === -1) return false
    if (value.wallet === null) return value.seedAccess === null
      && String(value.cocoSession.state) === "stopped"
    if (!value.seedAccess) return false
    return ["locked", "available"].indexOf(String(value.seedAccess.state || "")) !== -1
      && typeof value.seedAccess.requiresPassphrase === "boolean"
  }

  function isBalanceCollection(value) {
    if (!value || !Array.isArray(value.items) || containsSensitiveKey(value)) return false
    for (var i = 0; i < value.items.length; i++) {
      var item = value.items[i]
      if (typeof item.mintUrl !== "string" || typeof item.unit !== "string"
          || !decimalString(item.spendable) || !decimalString(item.reserved)
          || !decimalString(item.total)) return false
    }
    return true
  }

  function isMintCollection(value) {
    if (!value || !Array.isArray(value.items) || containsSensitiveKey(value)) return false
    for (var i = 0; i < value.items.length; i++) {
      if (typeof value.items[i].mintUrl !== "string"
          || typeof value.items[i].trusted !== "boolean") return false
    }
    return true
  }

  function isOperationCollection(value, type) {
    if (!value || !Array.isArray(value.items) || containsSensitiveKey(value)) return false
    if (typeof value.offset !== "number" || Math.floor(value.offset) !== value.offset
        || value.offset < 0 || typeof value.limit !== "number"
        || Math.floor(value.limit) !== value.limit || value.limit < 1 || value.limit > 100)
      return false
    for (var i = 0; i < value.items.length; i++) {
      var item = value.items[i]
      if (String(item.type || "") !== type || typeof item.id !== "string"
          || typeof item.state !== "string" || typeof item.mintUrl !== "string"
          || typeof item.unit !== "string") return false
      if (type === "receive" && !decimalString(item.amount)) return false
      if (type === "send" && !isSendOperation(item)) return false
    }
    return true
  }

  function isReceiveOperation(value) {
    if (!isOperationCollection({ items: [value], offset: 0, limit: 1 }, "receive"))
      return false
    var state = String(value.state || "")
    if (["init", "prepared", "executing", "finalized", "rolled_back"]
        .indexOf(state) === -1
        || typeof value.createdAt !== "string" || typeof value.updatedAt !== "string")
      return false
    if (state === "init") return value.fee === undefined || decimalString(value.fee)
    return decimalString(value.fee)
  }

  function operationAmount(value) {
    if (!value || typeof value !== "object") return ""
    var requested = decimalString(value.requestedAmount)
    var legacy = decimalString(value.amount)
    if (requested && legacy && requested !== legacy) return ""
    return requested || legacy
  }

  function projectSendOperation(value) {
    if (!isSendOperation(value)) return null
    return {
      id: String(value.id),
      type: "send",
      state: String(value.state),
      mintUrl: String(value.mintUrl),
      unit: String(value.unit),
      method: String(value.method || "default"),
      requestedAmount: operationAmount(value),
      amount: operationAmount(value),
      fee: value.fee === undefined ? undefined : String(value.fee),
      inputAmount: value.inputAmount === undefined
        ? undefined : String(value.inputAmount),
      needsSwap: value.needsSwap,
      createdAt: String(value.createdAt),
      updatedAt: String(value.updatedAt)
    }
  }

  function isSendOperation(value) {
    if (!value || typeof value !== "object" || containsSensitiveKey(value)
        || value.type !== "send" || typeof value.id !== "string"
        || value.id.length === 0
        || typeof value.mintUrl !== "string" || value.mintUrl.length === 0
        || value.unit !== "sat" || !operationAmount(value)
        || typeof value.createdAt !== "string" || typeof value.updatedAt !== "string")
      return false
    if (value.method !== undefined
        && ["default", "p2pk"].indexOf(String(value.method)) === -1) return false
    var state = String(value.state || "")
    if (["init", "prepared", "executing", "pending", "finalized",
        "rolling_back", "rolled_back"].indexOf(state) === -1) return false
    if (state === "init") return (value.fee === undefined || decimalString(value.fee))
      && (value.inputAmount === undefined || decimalString(value.inputAmount))
      && (value.needsSwap === undefined || typeof value.needsSwap === "boolean")
    return decimalString(value.fee) && decimalString(value.inputAmount)
      && typeof value.needsSwap === "boolean"
  }

  function isSendResult(value) {
    if (!value || typeof value !== "object"
        || typeof value.token !== "string" || value.token.length === 0)
      return false
    var keys = Object.keys(value)
    return keys.length === 1 && keys[0] === "token"
  }

  function parseErrorDocument(request) {
    var value
    try {
      value = JSON.parse(request.responseText || "")
    } catch (error) {
      return { code: "invalid_error_document", retryable: false }
    }
    if (!value || !value.error || typeof value.error.code !== "string"
        || typeof value.error.retryable !== "boolean")
      return { code: "invalid_error_document", retryable: false }
    return { code: normalizeNetworkErrorCode(value.error.code),
      retryable: value.error.retryable }
  }

  function normalizeNetworkErrorCode(code) {
    var aliases = {
      not_found: "operation_not_found",
      invalid_operation_state: "operation_conflict",
      operation_in_progress: "operation_conflict",
      operation_result_not_available: "result_not_available"
    }
    var value = String(code || "")
    return aliases[value] || value
  }

  function sendRequest(method, path, body, callback, accept) {
    var credential = clientCredential()
    if (!credential) return null
    var request = new XMLHttpRequest()
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE) return
      if (request.status < 200 || request.status >= 300) {
        var error = request.status === 0
          ? { code: "transport_unavailable", retryable: true }
          : root.parseErrorDocument(request)
        callback({ ok: false, status: request.status, error: error })
        return
      }
      var value
      try {
        value = JSON.parse(request.responseText || "")
      } catch (parseFailure) {
        callback({
          ok: false,
          status: request.status,
          error: { code: "invalid_response", retryable: true }
        })
        return
      }
      callback({ ok: true, status: request.status, value: value })
    }
    request.open(method, daemonBaseUrl + path, true)
    request.setRequestHeader("Accept", accept || "application/json")
    request.setRequestHeader("Authorization", "Bearer " + credential)
    if (body !== undefined) request.setRequestHeader("Content-Type", "application/json")
    if (body === undefined) request.send()
    else request.send(JSON.stringify(body))
    return request
  }

  function abortRequests(requests) {
    var values = Array.isArray(requests) ? requests : []
    for (var i = 0; i < values.length; i++) if (values[i]) {
      values[i].onreadystatechange = null
      values[i].abort()
    }
  }

  function abortIncrementalSendFetches() {
    abortRequests(sendRequests)
    sendRequests = []
    var request = balanceRequest
    balanceRequest = null
    if (request) {
      request.onreadystatechange = null
      request.abort()
    }
    for (var operationId in sendLookupRequestsById) {
      var lookup = sendLookupRequestsById[operationId]
      if (lookup) {
        lookup.onreadystatechange = null
        lookup.abort()
      }
    }
    sendLookupRequestsById = ({})
    queuedSendOperationInvalidations = ({})
  }

  function resumeQueuedSendInvalidations() {
    if (fullFetchInProgress || sendCanonicalMutationBusy()) return
    var refreshSends = queuedSendInvalidation
    var refreshBalances = queuedBalanceInvalidation
    queuedSendInvalidation = false
    queuedBalanceInvalidation = false
    if (refreshSends) fetchOperationGroup("send")
    if (refreshBalances) fetchBalances()
    var queuedOperations = queuedSendOperationInvalidations
    queuedSendOperationInvalidations = ({})
    for (var operationId in queuedOperations) refetchSendOperation(operationId)
  }

  function collectSendResources(specifications, callback, failureCallback) {
    abortIncrementalSendFetches()
    abortRequests(sendReconcileRequests)
    sendReconcileRequests = []
    var values = ({})
    var pending = specifications.length
    var requests = []
    var failed = false

    function reject(code) {
      if (failed) return
      failed = true
      root.abortRequests(requests)
      root.sendReconcileRequests = []
      if (typeof failureCallback === "function") failureCallback(code)
      else root.failSend(code)
    }

    for (var index = 0; index < specifications.length; index++) {
      (function(specification) {
        var request = root.sendRequest("GET", specification.path, undefined,
          function(result) {
            if (failed || requests.indexOf(request) === -1) return
            if (!result.ok) {
              reject(result.error.code)
              return
            }
            var valid = specification.type === "balances"
              ? root.isBalanceCollection(result.value)
              : root.isOperationCollection(result.value, "send")
            if (result.status !== 200 || !valid) {
              reject("invalid_response")
              return
            }
            values[specification.key] = result.value
            pending--
            if (pending !== 0) return
            root.sendReconcileRequests = []
            callback(values)
          })
        if (!request) {
          reject("credential_unavailable")
          return
        }
        requests.push(request)
      })(specifications[index])
    }
    sendReconcileRequests = requests
    return !failed
  }

  function abortCanonicalRequests() {
    var requests = canonicalRequests
    canonicalRequests = []
    abortRequests(requests)
  }

  function sendCanonicalMutationBusy() {
    return !!sendCommandRequest || sendReconcileRequests.length > 0
      || sendResultReconciling
      || ["preparing", "cancelling", "executing",
        "recovering-result", "reclaiming"]
        .indexOf(sendState) !== -1
  }

  function resumeDeferredCanonicalReconcile() {
    var reason = String(deferredReconcileReason || "")
    if (!reason) {
      resumeQueuedSendInvalidations()
      return
    }
    if (fullFetchInProgress || sendCanonicalMutationBusy()) return
    deferredReconcileReason = ""
    beginReconcile(reason)
  }

  function beginReconcile(reason) {
    var requestedReason = String(reason || "manual")
    if (fullFetchInProgress || sendCanonicalMutationBusy()) {
      if (deferredReconcileReason !== "rotation" || requestedReason === "rotation")
        deferredReconcileReason = requestedReason
      return
    }
    deferredReconcileReason = ""
    var preserveHealthyStream = !!streamRequest
      && requestedReason !== "startup" && requestedReason !== "rotation"
    reconnectTimer.stop()
    if (!preserveHealthyStream) {
      heartbeatTimer.stop()
      rotationTimer.stop()
      stopStream()
    }
    abortCanonicalRequests()
    if (!daemonUrlAllowed) {
      compatibilityState = "unknown"
      connectionState = "error"
      connectionDetail = "cocod URL must use HTTP on loopback"
      lastErrorCode = "invalid_daemon_url"
      retryAttempt = 0
      retryDelayMs = 0
      return
    }
    if (!clientCredential()) {
      compatibilityState = "unknown"
      connectionState = "error"
      connectionDetail = "The cocod Client Credential is unavailable"
      lastErrorCode = "credential_unavailable"
      retryAttempt = 0
      retryDelayMs = 0
      return
    }
    if (requestedReason === "startup") {
      connectionState = "connecting"
      connectionDetail = "Connecting to cocod on loopback"
    } else if (requestedReason === "panel" && preserveHealthyStream) {
      connectionDetail = "Refreshing canonical Wallet resources"
    } else {
      reconnectCount++
      connectionState = "reconnecting"
      connectionDetail = "Refreshing canonical Wallet resources"
    }
    lastErrorCode = ""
    fetchAllCanonicalResources(!preserveHealthyStream)
  }

  function fetchAllCanonicalResources(connectAfterward) {
    abortCanonicalRequests()
    receiveResourceGeneration++
    receiveLookupTokens = ({})
    fullFetchInProgress = true
    var token = ++fullFetchToken
    var capabilityRequest = sendRequest("GET", "/v1/openapi.json", undefined,
      function(result) {
        if (token !== root.fullFetchToken) return
        if (!result.ok) {
          root.handleFetchFailure(result)
          return
        }
        if (!root.isOpenApiShape(result.value)) {
          root.fullFetchInProgress = false
          root.queuedReceiveInvalidations = ({})
          root.compatibilityState = "incompatible"
          root.connectionState = "error"
          root.connectionDetail = "Required cocod v1 OpenAPI resources are unavailable"
          root.lastErrorCode = "incompatible_contract"
          root.abortCanonicalRequests()
          return
        }
        root.fetchLifecycleForBootstrap(token, result.value, connectAfterward)
      })
    if (!capabilityRequest) {
      handleCredentialUnavailable()
      return
    }
    canonicalRequests = [capabilityRequest]
  }

  function fetchLifecycleForBootstrap(token, openApi, connectAfterward) {
    var request = sendRequest("GET", "/v1/status", undefined, function(result) {
      if (token !== root.fullFetchToken) return
      if (!result.ok) {
        root.handleFetchFailure(result)
        return
      }
      if (!root.isStatusShape(result.value) || root.containsSensitiveKey(result.value)) {
        root.handleContractFailure("invalid_status", "cocod returned an invalid lifecycle status")
        return
      }
      if (!result.value.wallet || String(result.value.cocoSession.state) !== "running") {
        root.finishFullFetch(openApi, result.value,
          { items: [] }, { items: [] }, [], [], connectAfterward)
        return
      }
      root.fetchWalletResources(token, openApi, result.value, connectAfterward)
    })
    if (!request) {
      handleCredentialUnavailable()
      return
    }
    canonicalRequests.push(request)
  }

  function fetchWalletResources(token, openApi, status, connectAfterward) {
    var specifications = [
      { key: "balances", path: "/v1/balances", type: "balances" },
      { key: "mints", path: "/v1/mints", type: "mints" },
      { key: "receivePrepared", path: "/v1/operations/receive/prepared", type: "receive" },
      { key: "receiveInFlight", path: "/v1/operations/receive/in-flight", type: "receive" },
      { key: "sendPrepared", path: "/v1/operations/send/prepared", type: "send" },
      { key: "sendInFlight", path: "/v1/operations/send/in-flight", type: "send" }
    ]
    var values = ({})
    var pending = specifications.length
    var failed = false
    for (var i = 0; i < specifications.length; i++) {
      (function(specification) {
        var request = root.sendRequest("GET", specification.path, undefined, function(result) {
          if (token !== root.fullFetchToken || failed) return
          if (!result.ok) {
            failed = true
            root.handleFetchFailure(result)
            return
          }
          var valid = specification.type === "balances" ? root.isBalanceCollection(result.value)
            : specification.type === "mints" ? root.isMintCollection(result.value)
            : root.isOperationCollection(result.value, specification.type)
          if (!valid) {
            failed = true
            root.handleContractFailure("invalid_" + specification.key,
              "cocod returned an invalid canonical resource")
            return
          }
          values[specification.key] = result.value
          pending--
          if (pending === 0) {
            var receiveSummaries = values.receivePrepared.items.concat(
              values.receiveInFlight.items)
            var sends = values.sendPrepared.items.concat(values.sendInFlight.items)
            root.inspectReceivesForFullFetch(token, receiveSummaries,
              function(receives, needsFreshBalances) {
                if (token !== root.fullFetchToken) return
                if (!needsFreshBalances) {
                  root.finishFullFetch(openApi, status, values.balances,
                    values.mints, receives, sends, connectAfterward)
                  return
                }
                var balanceRequest = root.sendRequest("GET", "/v1/balances", undefined,
                  function(balanceResult) {
                    if (token !== root.fullFetchToken) return
                    if (!balanceResult.ok) {
                      root.handleFetchFailure(balanceResult)
                      return
                    }
                    if (!root.isBalanceCollection(balanceResult.value)) {
                      root.handleContractFailure("invalid_balances",
                        "cocod returned invalid balances")
                      return
                    }
                    root.finishFullFetch(openApi, status, balanceResult.value,
                      values.mints, receives, sends, connectAfterward)
                  })
                if (!balanceRequest) {
                  root.handleCredentialUnavailable()
                  return
                }
                root.canonicalRequests.push(balanceRequest)
              })
          }
        })
        if (!request) {
          failed = true
          root.handleCredentialUnavailable()
          return
        }
        root.canonicalRequests.push(request)
      })(specifications[i])
    }
  }

  function setReceiveRecoveryFromOperation(operation) {
    var state = String(operation.state || "")
    var id = String(operation.id || "")
    if (["init", "executing"].indexOf(state) !== -1) {
      updateReceiveRecovery(id, "recovering", "")
      return true
    }
    if (state === "finalized") {
      updateReceiveRecovery(id, "finalized", "")
      return false
    }
    if (state === "rolled_back") {
      updateReceiveRecovery(id, "rolled_back",
        receiveErrorMessage("operation_conflict"))
      return false
    }
    return state === "prepared"
  }

  function setReceiveRecoveryFailure(operationId, error) {
    updateReceiveRecovery(operationId,
      error && error.retryable ? "unavailable" : "failed",
      receiveRecoveryErrorMessage(error ? error.code : "invalid_response"))
  }

  function receiveRecoveryErrorMessage(code) {
    if (String(code || "") === "coco_error")
      return "cocod could not reconcile this Receive. Retry when the Mint is available."
    return receiveErrorMessage(code)
  }

  function reconcileCanonicalReceive(options, callback) {
    var id = String(options.operationId || "")
    var generation = options.generation
    var sequence = nextReceiveLookupToken(id)
    var fallback = options.fallback || null
    var trackRecovery = options.trackRecovery !== false
    var fullFetch = options.fullFetch === true
    function current() {
      return root.receiveLookupIsCurrent(id, sequence, generation)
    }
    function track(request) {
      if (fullFetch) root.canonicalRequests.push(request)
    }
    function complete(operation, needsFreshBalances, error, contractError,
        credentialUnavailable) {
      if (!current()) return
      callback({
        operation: operation,
        needsFreshBalances: needsFreshBalances,
        error: error || null,
        contractError: contractError || "",
        credentialUnavailable: credentialUnavailable === true
      })
    }
    function project(operation) {
      var state = String(operation.state || "")
      if (["init", "executing"].indexOf(state) === -1) {
        var active = trackRecovery
          ? root.setReceiveRecoveryFromOperation(operation)
          : state === "prepared"
        complete(active ? operation : null,
          ["finalized", "rolled_back"].indexOf(state) !== -1)
        return
      }
      if (trackRecovery) root.setReceiveRecoveryFromOperation(operation)
      var refreshRequest = root.sendRequest("POST", "/v1/operations/receive/"
        + encodeURIComponent(id) + "/refresh", undefined, function(result) {
          if (!current()) return
          if (!result.ok) {
            if (trackRecovery) root.setReceiveRecoveryFailure(id, result.error)
            complete(result.error.code === "operation_not_found" ? null : operation,
              true, result.error)
            return
          }
          if (result.status !== 200 || !root.isReceiveOperation(result.value)) {
            var invalid = { code: "invalid_response", retryable: false }
            if (trackRecovery) root.setReceiveRecoveryFailure(id, invalid)
            complete(operation, true, null, "invalid_receive_operation")
            return
          }
          var active = trackRecovery
            ? root.setReceiveRecoveryFromOperation(result.value)
            : ["init", "prepared", "executing"].indexOf(
              String(result.value.state || "")) !== -1
          complete(active ? result.value : null, true)
        })
      if (!refreshRequest) {
        var credentialError = { code: "credential_unavailable", retryable: false }
        if (trackRecovery) root.setReceiveRecoveryFailure(id, credentialError)
        complete(operation, true, credentialError, "", true)
        return
      }
      track(refreshRequest)
    }
    if (!id) {
      complete(null, false, null, "invalid_receive_operation")
      return
    }
    var lookupRequest = sendRequest("GET", "/v1/operations/receive/"
      + encodeURIComponent(id), undefined, function(result) {
        if (!current()) return
        if (!result.ok) {
          if (trackRecovery) root.setReceiveRecoveryFailure(id, result.error)
          complete(result.error.code === "operation_not_found" ? null : fallback,
            true, result.error)
          return
        }
        if (result.status !== 200 || !root.isReceiveOperation(result.value)) {
          var invalid = { code: "invalid_response", retryable: false }
          if (trackRecovery) root.setReceiveRecoveryFailure(id, invalid)
          complete(null, true, null, "invalid_receive_operation")
          return
        }
        project(result.value)
      })
    if (!lookupRequest) {
      var credentialError = { code: "credential_unavailable", retryable: false }
      if (trackRecovery) root.setReceiveRecoveryFailure(id, credentialError)
      complete(fallback, true, credentialError, "", true)
      return
    }
    track(lookupRequest)
  }

  function inspectReceivesForFullFetch(token, summaries, callback) {
    var unique = []
    var seen = ({})
    var source = Array.isArray(summaries) ? summaries : []
    for (var i = 0; i < source.length; i++) {
      var id = String(source[i].id || "")
      if (!id || seen[id]) continue
      seen[id] = true
      unique.push(source[i])
    }
    if (unique.length === 0) {
      callback([], false)
      return
    }
    var values = []
    var pending = unique.length
    var failed = false
    var needsFreshBalances = false
    for (var index = 0; index < unique.length; index++) {
      (function(summary) {
        root.reconcileCanonicalReceive({
          operationId: summary.id,
          generation: root.receiveResourceGeneration,
          fallback: summary,
          trackRecovery: true,
          fullFetch: true
        }, function(result) {
          if (failed || token !== root.fullFetchToken) return
          if (result.credentialUnavailable) {
            failed = true
            root.handleCredentialUnavailable()
            return
          }
          if (result.contractError) {
            failed = true
            root.handleContractFailure(result.contractError,
              "cocod returned an invalid Receive Operation")
            return
          }
          if (result.operation) values.push(result.operation)
          needsFreshBalances = needsFreshBalances || result.needsFreshBalances
          pending--
          if (pending === 0) callback(values, needsFreshBalances)
        })
      })(unique[index])
    }
  }

  function finishFullFetch(openApi, status, balances, mints, receives, sends,
      connectAfterward) {
    var queuedInvalidations = queuedReceiveInvalidations
    queuedReceiveInvalidations = ({})
    fullFetchInProgress = false
    canonicalRequests = []
    openApiResource = openApi
    statusResource = status
    balancesResource = balances
    mintsResource = mints
    receiveOperations = receives
    sendOperations = sends
    compatibilityState = "compatible"
    connectionState = "connected"
    connectionDetail = "Connected to cocod"
    lastErrorCode = ""
    retryAttempt = 0
    retryDelayMs = 0
    refreshCount++
    var sessionState = String(status.cocoSession.state || "")
    if (creating && status.wallet && sessionState === "starting") {
      createSettlementAttempts++
      if (createSettlementAttempts < createSettlementMaximumAttempts)
        createSettlementTimer.restart()
      else {
        creating = false
        createError = "Wallet created, but its Coco Session is still starting"
      }
    } else if (walletState !== "uninitialized") {
      createSettlementTimer.stop()
      createSettlementAttempts = 0
      creating = false
      createError = status.cocoSession.lastFailure
        ? "Wallet created, but its Coco Session could not start" : ""
    }
    if (connectAfterward && walletState === "unlocked") startStream()
    if (receiveState === "reconciling" && receiveOperationId)
      reconcileReceiveOperation(receiveOperationId)
    reconcileAmbiguousReceiveFromCanonical()
    for (var operationId in queuedInvalidations)
      refetchReceiveOperation(operationId)
    reconcileAmbiguousSendFromCanonical()
    if (sendCancelOnPrepared && sendOperationId
        && ["review", "error"].indexOf(sendState) !== -1) {
      if (cancelPreparedSend()) sendCancelOnPrepared = false
    } else if (sendCancelOnPrepared && !sendAmbiguousCreation) {
      sendCancelOnPrepared = false
      resetSend()
    }
    resumeDeferredCanonicalReconcile()
  }

  function handleCredentialUnavailable() {
    fullFetchInProgress = false
    queuedReceiveInvalidations = ({})
    connectionState = "error"
    compatibilityState = "unknown"
    connectionDetail = "The cocod Client Credential is unavailable"
    lastErrorCode = "credential_unavailable"
    retryAttempt = 0
    retryDelayMs = 0
  }

  function handleFetchFailure(result) {
    fullFetchInProgress = false
    queuedReceiveInvalidations = ({})
    abortCanonicalRequests()
    compatibilityState = "unknown"
    lastErrorCode = result.error.code
    if (result.status === 0 && refreshCount === 0) {
      connectionState = "missing"
      connectionDetail = "No compatible cocod is listening on loopback"
    } else if (result.error.code === "invalid_response"
        || result.error.code === "invalid_error_document") {
      connectionState = "error"
      connectionDetail = "cocod returned an invalid response"
    } else {
      connectionState = "unavailable"
      connectionDetail = "cocod request failed with " + result.error.code
    }
    scheduleReconnect(false, !!streamRequest)
  }

  function handleContractFailure(code, detail) {
    fullFetchInProgress = false
    queuedReceiveInvalidations = ({})
    abortCanonicalRequests()
    compatibilityState = "unknown"
    connectionState = "error"
    connectionDetail = detail
    lastErrorCode = code
    scheduleReconnect(false, false)
  }

  function resetReceive() {
    if (["preparing", "cancelling", "executing", "reconciling"]
        .indexOf(receiveState) !== -1) return false
    if (receiveState === "review" && receivePreparedOperation) return false
    if (receiveAmbiguousCreation) {
      receiveCancelOnPrepared = true
      retryAmbiguousReceiveReconciliation()
      return false
    }
    var request = receiveRequest
    receiveRequest = null
    if (request) {
      request.onreadystatechange = null
      request.abort()
    }
    receiveReconcileToken++
    abortRequests(receiveReconcileRequests)
    receiveReconcileRequests = []
    receiveState = "idle"
    receiveError = ""
    receiveOperationId = ""
    receiveCancelOnPrepared = false
    receiveAmbiguousCreation = null
    return true
  }

  function beginReceiveFlow() {
    if (["preparing", "cancelling", "executing", "reconciling"]
        .indexOf(receiveState) !== -1) return false
    receiveCancelOnPrepared = false
    var prepared = receivePreparedOperation || firstCanonicalPreparedReceive()
    if (prepared) {
      receiveOperationId = String(prepared.id)
      receiveError = ""
      if (String(prepared.unit || "") !== "sat")
        return cancelUnsupportedReceive(receiveOperationId)
      receiveState = "review"
      return true
    }
    if (receiveState === "error" && receiveAmbiguousCreation) {
      retryAmbiguousReceiveReconciliation()
      return true
    }
    return resetReceive()
  }

  function dismissReceiveFlow() {
    if (receiveState === "preparing") {
      receiveCancelOnPrepared = true
      return true
    }
    if (receiveState === "cancelling") return true
    if (["executing", "reconciling"].indexOf(receiveState) !== -1) return false
    if (receiveAmbiguousCreation) {
      receiveCancelOnPrepared = true
      retryAmbiguousReceiveReconciliation()
      return true
    }
    if (receiveState === "review" && receivePreparedOperation)
      return cancelPreparedReceive()
    return resetReceive()
  }

  function resetSend() {
    if (["preparing", "cancelling", "executing", "reclaiming"]
        .indexOf(sendState) !== -1
        || (sendState === "review" && sendPreparedOperation)
        || sendResultReconciling) return false
    var request = sendCommandRequest
    sendCommandRequest = null
    if (request) {
      request.onreadystatechange = null
      request.abort()
    }
    abortRequests(sendReconcileRequests)
    sendReconcileRequests = []
    sendState = "idle"
    sendError = ""
    sendErrorCode = ""
    sendOperationId = ""
    sendCancelOnPrepared = false
    sendAmbiguousCreation = null
    sendDismissAfterResult = false
    resumeDeferredCanonicalReconcile()
    return true
  }

  function beginSendFlow() {
    if (["preparing", "cancelling", "executing", "reclaiming"]
        .indexOf(sendState) !== -1 || sendResultReconciling) return false
    sendCancelOnPrepared = false
    var pending = sendPendingOperation || firstCanonicalPendingSend()
    if (pending) {
      sendOperationId = String(pending.id)
      sendError = ""
      sendErrorCode = ""
      return retrievePendingSendResult(sendOperationId)
    }
    var prepared = sendPreparedOperation || firstCanonicalPreparedSend()
    if (prepared) {
      sendOperationId = String(prepared.id)
      sendError = ""
      sendErrorCode = ""
      sendState = "review"
      return true
    }
    if (sendState === "error"
        && (sendOperationId !== "" || sendAmbiguousCreation)) return true
    return resetSend()
  }

  function dismissSendFlow() {
    if (sendState === "preparing") {
      sendCancelOnPrepared = true
      return true
    }
    if (["executing", "reclaiming"].indexOf(sendState) !== -1) return false
    if (sendState === "cancelling") return true
    if (sendState === "result" && sendResultReconciling) {
      sendDismissAfterResult = true
      return true
    }
    if (sendAmbiguousCreation) {
      sendCancelOnPrepared = true
      beginReconcile("send-ambiguous-dismiss")
      return true
    }
    if (sendCanCancelReservation) {
      if (fullFetchInProgress) {
        sendCancelOnPrepared = true
        return true
      }
      sendCancelOnPrepared = false
      return cancelPreparedSend()
    }
    return resetSend()
  }

  function cancelSendFlow() {
    if (sendCanCancelReservation) {
      if (fullFetchInProgress) {
        sendCancelOnPrepared = true
        return "dismissed"
      }
      return cancelPreparedSend() ? "cancelling" : ""
    }
    if (sendAmbiguousCreation) {
      sendCancelOnPrepared = true
      beginReconcile("send-ambiguous-dismiss")
      return "dismissed"
    }
    return resetSend() ? "dismissed" : ""
  }

  function reconcileFailedReclaim(code, operationId) {
    sendErrorCode = String(code || "")
    sendError = sendErrorMessage(code)
    sendState = "error"
    reconcileSendResources(function() {
      var canonical = root.canonicalSendOperation(operationId)
      if (!canonical || String(canonical.state || "") !== "pending")
        root.sendOperationId = ""
      root.resumeDeferredCanonicalReconcile()
    }, function() {
      root.fetchOperationGroup("send")
      root.fetchBalances()
      root.resumeDeferredCanonicalReconcile()
    })
  }

  function prepareSend(mintUrl, amount) {
    var selectedMint = String(mintUrl || "")
    var requestedAmount = String(amount === undefined || amount === null ? "" : amount)
    if (!/^[1-9][0-9]*$/.test(requestedAmount) || !selectedMint
        || fullFetchInProgress
        || sendCommandRequest || sendState !== "idle") return false
    var eligible = sendMintOptions(requestedAmount)
    var canFund = false
    for (var index = 0; index < eligible.length; index++)
      if (String(eligible[index].mintUrl || "") === selectedMint) canFund = true
    if (!canFund) return false
    var knownOperationIds = ({})
    for (var operationIndex = 0; operationIndex < sendOperations.length;
        operationIndex++)
      knownOperationIds[String(sendOperations[operationIndex].id || "")] = true
    sendError = ""
    sendErrorCode = ""
    sendOperationId = ""
    sendCancelOnPrepared = false
    sendAmbiguousCreation = null
    abortIncrementalSendFetches()
    sendState = "preparing"
    var request = root.sendRequest("POST", "/v1/operations/send", {
      mintUrl: selectedMint,
      unit: "sat",
      amount: requestedAmount
    }, function(result) {
      if (request !== root.sendCommandRequest) return
      root.sendCommandRequest = null
      if (!result.ok) {
        if (result.status === 0
            || (result.status === 201 && result.error.code === "invalid_response")) {
          root.reconcileAmbiguousSendCreation(selectedMint, requestedAmount,
            knownOperationIds, result.error.code)
          return
        }
        if (result.error.code === "coco_error") {
          root.reconcileSendResources(function() {
            root.failSend("coco_error")
          }, function() {
            root.failSend("coco_error")
          })
          return
        }
        root.failSend(result.error.code)
        return
      }
      if (result.status !== 201 || !root.isSendOperation(result.value)
          || String(result.value.state) !== "prepared"
          || String(result.value.mintUrl) !== selectedMint
          || root.operationAmount(result.value) !== requestedAmount) {
        if (result.status === 201)
          root.reconcileAmbiguousSendCreation(selectedMint, requestedAmount,
            knownOperationIds, "invalid_response")
        else root.failSend("invalid_response")
        return
      }
      root.sendAmbiguousCreation = null
      root.sendOperationId = String(result.value.id)
      root.reconcileSendResources(function() {
        root.finishPreparedSendReconciliation("")
      }, function(code) {
        root.finishPreparedSendReconciliation(code)
      })
    })
    if (!request) {
      failSend("credential_unavailable")
      return false
    }
    sendCommandRequest = request
    return true
  }

  function reconcileAmbiguousSendCreation(mintUrl, amount, knownOperationIds,
      failureCode) {
    sendAmbiguousCreation = {
      mintUrl: String(mintUrl),
      amount: String(amount),
      knownOperationIds: knownOperationIds,
      failureCode: String(failureCode || "transport_unavailable")
    }
    sendState = "preparing"
    reconcileSendResources(function() {
      var match = root.matchAmbiguousSendCreation(root.sendAmbiguousCreation)
      if (match.matches !== 1) {
        if (match.matches === 0) root.sendAmbiguousCreation = null
        root.failSend(match.matches > 1 ? "invalid_response" : failureCode)
        return
      }
      root.sendAmbiguousCreation = null
      root.sendOperationId = String(match.operation.id)
      root.finishPreparedSendReconciliation("")
    }, function() {
      root.failSend(failureCode)
    })
  }

  function matchAmbiguousSendCreation(context) {
    var result = { operation: null, matches: 0 }
    if (!context) return result
    var known = context.knownOperationIds || ({})
    for (var index = 0; index < sendOperations.length; index++) {
      var operation = sendOperations[index]
      var operationId = String(operation.id || "")
      if (known[operationId] || String(operation.state || "") !== "prepared"
          || String(operation.mintUrl || "") !== String(context.mintUrl || "")
          || root.operationAmount(operation) !== String(context.amount || "")) continue
      result.operation = operation
      result.matches++
    }
    return result
  }

  function reconcileAmbiguousSendFromCanonical() {
    if (!sendAmbiguousCreation) return
    var context = sendAmbiguousCreation
    var match = matchAmbiguousSendCreation(context)
    if (match.matches === 1) {
      sendAmbiguousCreation = null
      sendOperationId = String(match.operation.id)
      finishPreparedSendReconciliation("")
      return
    }
    if (match.matches > 1) {
      failSend("invalid_response")
      return
    }
    sendAmbiguousCreation = null
    if (sendCancelOnPrepared) {
      sendCancelOnPrepared = false
      resetSend()
    } else if (sendState === "preparing") {
      failSend(String(context.failureCode || "transport_unavailable"))
    }
  }

  function finishPreparedSendReconciliation(code) {
    if (code) failSend(code)
    else if (!sendPreparedOperation) failSend("invalid_response")
    else sendState = "review"
    if (sendCancelOnPrepared && sendOperationId && cancelPreparedSend()) {
      sendCancelOnPrepared = false
      return
    }
    resumeDeferredCanonicalReconcile()
  }

  function cancelPreparedSend() {
    var operationId = String(sendOperationId || "")
    if (!operationId || fullFetchInProgress || !sendCanCancelReservation) return false
    abortIncrementalSendFetches()
    sendState = "cancelling"
    sendError = ""
    sendErrorCode = ""
    var request = root.sendRequest("POST", "/v1/operations/send/"
      + encodeURIComponent(operationId) + "/cancel", undefined, function(result) {
        if (request !== root.sendCommandRequest) return
        root.sendCommandRequest = null
        if (!result.ok) {
          if (["operation_not_found", "operation_conflict"]
              .indexOf(result.error.code) !== -1)
            root.reconcileSendCommandFailure(result.error.code, operationId)
          else root.failSend(result.error.code)
          return
        }
        if (result.status !== 200 || !root.isSendOperation(result.value)
            || String(result.value.id) !== operationId
            || String(result.value.state) !== "rolled_back") {
          root.failSend("invalid_response")
          return
        }
        root.sendOperationId = ""
        root.reconcileSendResources(function() {
          root.sendState = "idle"
          root.resumeDeferredCanonicalReconcile()
        })
      })
    if (!request) {
      failSend("credential_unavailable")
      return false
    }
    sendCommandRequest = request
    return true
  }

  function reconcileSendCommandFailure(code, operationId) {
    sendErrorCode = String(code || "")
    sendError = sendErrorMessage(code)
    reconcileSendResources(function() {
      var canonical = null
      for (var index = 0; index < root.sendOperations.length; index++)
        if (String(root.sendOperations[index].id || "") === String(operationId))
          canonical = root.sendOperations[index]
      if (canonical && String(canonical.state || "") === "prepared") {
        root.sendOperationId = String(canonical.id)
      } else {
        root.sendOperationId = ""
      }
      root.sendState = "error"
      root.resumeDeferredCanonicalReconcile()
    })
  }

  function executePreparedSend() {
    var operation = sendPreparedOperation
    var operationId = operation ? String(operation.id || "") : ""
    if (!operationId || !sendCommandsAvailable || sendCommandRequest
        || sendState !== "review") return false
    abortIncrementalSendFetches()
    sendState = "executing"
    sendError = ""
    sendErrorCode = ""
    var request = root.sendRequest("POST", "/v1/operations/send/"
      + encodeURIComponent(operationId) + "/execute", undefined, function(result) {
        if (request !== root.sendCommandRequest) return
        root.sendCommandRequest = null
        if (!result.ok) {
          if (["operation_not_found", "operation_conflict"]
              .indexOf(result.error.code) !== -1)
            root.reconcileSendCommandFailure(result.error.code, operationId)
          else root.failSend(result.error.code)
          return
        }
        var operation = result.value && result.value.operation
          ? result.value.operation : null
        var resultDocument = result.value && result.value.result
          ? result.value.result : null
        if (result.status !== 200 || !root.isSendOperation(operation)
            || String(operation.id) !== operationId
            || String(operation.state) !== "pending"
            || !root.isSendResult(resultDocument)) {
          root.failSend("invalid_response")
          return
        }
        var outgoingToken = String(resultDocument.token)
        resultDocument.token = ""
        root.sendOperationId = operationId
        root.sendResultReconciling = true
        root.sendDismissAfterResult = false
        root.sendState = "result"
        root.sendExecuted(outgoingToken)
        outgoingToken = ""
        root.reconcileSendResources(function() {
          root.finishSendResultReconciliation()
        }, function() {
          root.fetchOperationGroup("send")
          root.fetchBalances()
          root.finishSendResultReconciliation()
        })
      })
    if (!request) {
      failSend("credential_unavailable")
      return false
    }
    sendCommandRequest = request
    return true
  }

  function retrievePendingSendResult(operationId) {
    var id = String(operationId || "")
    var operation = canonicalSendOperation(id)
    if (!id || !operation || String(operation.state || "") !== "pending"
        || fullFetchInProgress || sendCommandRequest) return false
    sendOperationId = id
    sendState = "recovering-result"
    sendError = ""
    sendErrorCode = ""
    var request = sendRequest("GET", "/v1/operations/send/"
      + encodeURIComponent(id) + "/result", undefined, function(result) {
        if (request !== root.sendCommandRequest) return
        root.sendCommandRequest = null
        if (!result.ok) {
          root.sendErrorCode = String(result.error.code || "")
          root.sendError = root.sendErrorMessage(result.error.code)
          root.sendState = result.error.code === "result_not_available"
            ? "pending" : "error"
          root.resumeDeferredCanonicalReconcile()
          return
        }
        if (result.status !== 200 || !root.isSendResult(result.value)) {
          root.failSend("invalid_response")
          return
        }
        var outgoingToken = String(result.value.token)
        result.value.token = ""
        root.sendState = "result"
        root.sendExecuted(outgoingToken)
        outgoingToken = ""
        root.resumeDeferredCanonicalReconcile()
      })
    if (!request) {
      failSend("credential_unavailable")
      return false
    }
    sendCommandRequest = request
    return true
  }

  function reclaimPendingSend() {
    var operation = sendPendingOperation
    var operationId = operation ? String(operation.id || "") : ""
    if (!operationId || !sendCanReclaim || !sendCommandsAvailable) return false
    abortIncrementalSendFetches()
    sendState = "reclaiming"
    sendError = ""
    sendErrorCode = ""
    var request = sendRequest("POST", "/v1/operations/send/"
      + encodeURIComponent(operationId) + "/reclaim", undefined, function(result) {
        if (request !== root.sendCommandRequest) return
        root.sendCommandRequest = null
        if (!result.ok) {
          root.reconcileFailedReclaim(result.error.code, operationId)
          return
        }
        if (result.status !== 200 || !root.isSendOperation(result.value)
            || String(result.value.id) !== operationId
            || String(result.value.state) !== "rolled_back") {
          root.failSend("invalid_response")
          return
        }
        root.sendResultReconciling = true
        root.reconcileSendResources(function() {
          root.sendOperationId = ""
          root.sendState = "reclaimed"
          root.finishSendResultReconciliation()
        }, function() {
          root.fetchOperationGroup("send")
          root.fetchBalances()
          root.sendOperationId = ""
          root.sendState = "reclaimed"
          root.finishSendResultReconciliation()
        })
      })
    if (!request) {
      failSend("credential_unavailable")
      return false
    }
    sendCommandRequest = request
    return true
  }

  function finishSendResultReconciliation() {
    sendResultReconciling = false
    if (sendDismissAfterResult) {
      sendDismissAfterResult = false
      resetSend()
    }
    resumeDeferredCanonicalReconcile()
  }

  function reconcileSendResources(callback, failureCallback) {
    var specifications = [
      { key: "prepared", path: "/v1/operations/send/prepared", type: "send" },
      { key: "inFlight", path: "/v1/operations/send/in-flight", type: "send" },
      { key: "balances", path: "/v1/balances", type: "balances" }
    ]
    collectSendResources(specifications, function(values) {
      root.sendOperations = values.prepared.items.concat(values.inFlight.items)
      root.balancesResource = values.balances
      root.refreshCount++
      callback()
    }, failureCallback)
  }

  function failSend(code) {
    sendCommandRequest = null
    sendState = "error"
    sendErrorCode = String(code || "")
    sendError = sendErrorMessage(code)
    resumeDeferredCanonicalReconcile()
  }

  function sendErrorMessage(code) {
    var messages = {
      invalid_request: "Enter a positive whole sat amount.",
      coco_error: "cocod could not complete this Send. Review the refreshed Wallet state, then try again or choose a smaller amount.",
      operation_not_found: "This Send is no longer available in cocod. Canonical Wallet state was refreshed.",
      operation_conflict: "This Send changed in cocod. Review the current Wallet state and try again.",
      result_not_available: "The outgoing token is not available yet. Check the Pending Send again.",
      credential_unavailable: "The cocod Client Credential is unavailable.",
      invalid_response: "cocod returned an invalid Send response.",
      transport_unavailable: "Send could not reach cocod. Try again."
    }
    return messages[String(code || "")] || "Send could not be completed. Try again."
  }

  function prepareReceive(token) {
    var normalizedToken = String(token || "").trim()
    if (!normalizedToken || receiveRequest || receiveState !== "idle"
        || connectionState !== "connected" || compatibilityState !== "compatible"
        || walletState !== "unlocked" || !receiveCommandsAvailable) return false
    receiveError = ""
    receiveOperationId = ""
    receiveCancelOnPrepared = false
    receiveAmbiguousCreation = null
    var knownOperationIds = ({})
    for (var operationIndex = 0; operationIndex < receiveOperations.length;
        operationIndex++)
      knownOperationIds[String(receiveOperations[operationIndex].id || "")] = true
    receiveState = "preparing"
    var request = sendRequest("POST", "/v1/operations/receive", {
      token: normalizedToken
    }, function(result) {
      if (request !== root.receiveRequest) return
      root.receiveRequest = null
      if (!result.ok) {
        if (result.status === 0
            || (result.status === 201 && result.error.code === "invalid_response")) {
          root.reconcileAmbiguousReceiveCreation(
            knownOperationIds, result.error.code)
          return
        }
        root.fetchOperationGroup("receive")
        root.failReceive(result.error.code)
        return
      }
      if (result.status !== 201 || !root.isReceiveOperation(result.value)
          || String(result.value.state) !== "prepared") {
        if (result.status === 201)
          root.reconcileAmbiguousReceiveCreation(
            knownOperationIds, "invalid_response")
        else root.failReceive("invalid_response")
        return
      }
      root.receiveAmbiguousCreation = null
      root.receiveOperationId = String(result.value.id)
      root.receiveOperations = root.withReceiveOperation(
        root.receiveOperations, result.value)
      if (String(result.value.unit || "") !== "sat") {
        root.cancelUnsupportedReceive(root.receiveOperationId)
        return
      }
      root.receiveState = "review"
      if (root.receiveCancelOnPrepared) root.cancelPreparedReceive()
    })
    normalizedToken = ""
    if (!request) {
      failReceive("credential_unavailable")
      return false
    }
    receiveRequest = request
    return true
  }

  function reconcileAmbiguousReceiveCreation(knownOperationIds, failureCode) {
    receiveAmbiguousCreation = {
      knownOperationIds: knownOperationIds,
      failureCode: String(failureCode || "transport_unavailable")
    }
    receiveState = "preparing"
    retryAmbiguousReceiveReconciliation()
  }

  function retryAmbiguousReceiveReconciliation() {
    if (!receiveAmbiguousCreation) return false
    receiveState = "preparing"
    reconcileReceiveResources(function() {
      root.reconcileAmbiguousReceiveFromCanonical()
    }, function(code) {
      var context = root.receiveAmbiguousCreation
      root.failReceive(code || (context
        ? context.failureCode : "transport_unavailable"), true)
    })
    return true
  }

  function reconcileReceiveResources(callback, failureCallback) {
    abortRequests(receiveRequests)
    receiveRequests = []
    var paths = [
      "/v1/operations/receive/prepared",
      "/v1/operations/receive/in-flight"
    ]
    var values = []
    var pending = paths.length
    var requests = []
    var failed = false

    function reject(code) {
      if (failed) return
      failed = true
      root.abortRequests(requests)
      root.receiveRequests = []
      failureCallback(code)
    }

    for (var index = 0; index < paths.length; index++) {
      (function(collectionIndex) {
        var request = root.sendRequest("GET", paths[collectionIndex], undefined,
          function(result) {
            if (failed || requests.indexOf(request) === -1) return
            if (!result.ok) {
              reject(result.error.code)
              return
            }
            if (result.status !== 200
                || !root.isOperationCollection(result.value, "receive")) {
              reject("invalid_response")
              return
            }
            values[collectionIndex] = result.value.items
            pending--
            if (pending !== 0) return
            root.receiveRequests = []
            root.receiveOperations = values[0].concat(values[1])
            root.refreshCount++
            callback()
          })
        if (!request) {
          reject("credential_unavailable")
          return
        }
        requests.push(request)
      })(index)
    }
    receiveRequests = requests
  }

  function matchAmbiguousReceiveCreation(context) {
    var result = { operation: null, matches: 0 }
    if (!context) return result
    var known = context.knownOperationIds || ({})
    for (var index = 0; index < receiveOperations.length; index++) {
      var operation = receiveOperations[index]
      var operationId = String(operation.id || "")
      if (known[operationId]
          || String(operation.state || "") !== "prepared") continue
      result.operation = operation
      result.matches++
    }
    return result
  }

  function reconcileAmbiguousReceiveFromCanonical() {
    if (!receiveAmbiguousCreation) return
    var context = receiveAmbiguousCreation
    var match = matchAmbiguousReceiveCreation(context)
    if (match.matches === 1) {
      receiveAmbiguousCreation = null
      receiveOperationId = String(match.operation.id)
      receiveError = ""
      if (String(match.operation.unit || "") !== "sat") {
        cancelUnsupportedReceive(receiveOperationId)
        return
      }
      receiveState = "review"
      if (receiveCancelOnPrepared) cancelPreparedReceive()
      return
    }
    receiveAmbiguousCreation = null
    if (match.matches > 1) {
      failReceive("invalid_response")
      return
    }
    if (receiveCancelOnPrepared) {
      receiveCancelOnPrepared = false
      resetReceive()
    } else if (receiveState === "preparing") {
      failReceive(String(context.failureCode || "transport_unavailable"))
    }
  }

  function cancelUnsupportedReceive(operationId) {
    var id = String(operationId || "")
    if (!id || receiveRequest || !receiveCommandsAvailable) {
      failReceive("unsupported_behavior")
      return false
    }
    receiveState = "cancelling"
    receiveError = ""
    var request = sendRequest("POST", "/v1/operations/receive/"
      + encodeURIComponent(id) + "/cancel", undefined, function(result) {
        if (request !== root.receiveRequest) return
        root.receiveRequest = null
        if (!result.ok) {
          root.fetchOperationGroup("receive")
          root.failReceive(result.error.code)
          return
        }
        if (result.status !== 200 || !root.isReceiveOperation(result.value)
            || String(result.value.id || "") !== id
            || String(result.value.state || "") !== "rolled_back") {
          root.failReceive("invalid_response")
          return
        }
        root.receiveOperations = root.withReceiveOperation(
          root.receiveOperations, result.value)
        root.failReceive("unsupported_behavior")
      })
    if (!request) {
      failReceive("credential_unavailable")
      return false
    }
    receiveRequest = request
    return true
  }

  function confirmReceive() {
    var operation = receivePreparedOperation
    var operationId = operation ? String(operation.id || "") : ""
    if (!operationId || receiveRequest || receiveState !== "review"
        || !receiveCommandsAvailable) return false
    receiveError = ""
    receiveState = "executing"
    executePreparedReceive(operationId)
    return true
  }

  function cancelPreparedReceive() {
    var operation = receivePreparedOperation
    var operationId = operation ? String(operation.id || "") : ""
    if (!operationId || receiveRequest
        || ["review", "cancelling"].indexOf(receiveState) === -1) return false
    receiveCancelOnPrepared = false
    receiveError = ""
    receiveState = "cancelling"
    var request = sendRequest("POST", "/v1/operations/receive/"
      + encodeURIComponent(operationId) + "/cancel", undefined, function(result) {
      if (request !== root.receiveRequest) return
      root.receiveRequest = null
      if (!result.ok) {
        root.fetchOperationGroup("receive")
        root.failReceive(result.error.code)
        return
      }
      if (result.status !== 200 || !root.isReceiveOperation(result.value)
          || String(result.value.id || "") !== operationId
          || String(result.value.state || "") !== "rolled_back") {
        root.failReceive("invalid_response")
        return
      }
      root.receiveOperations = root.withReceiveOperation(
        root.receiveOperations, result.value)
      root.receiveOperationId = ""
      root.receiveState = "idle"
      root.receiveError = ""
    })
    if (!request) {
      failReceive("credential_unavailable")
      return false
    }
    receiveRequest = request
    return true
  }

  function executePreparedReceive(operationId) {
    var request = sendRequest("POST", "/v1/operations/receive/"
      + encodeURIComponent(operationId) + "/execute", undefined, function(result) {
        if (request !== root.receiveRequest) return
        root.receiveRequest = null
        if (!result.ok) {
          root.fetchOperationGroup("receive")
          root.failReceive(result.error.code)
          return
        }
        if (result.status !== 200 || !root.isReceiveOperation(result.value)) {
          root.failReceive("invalid_response")
          return
        }
        root.receiveState = "reconciling"
        root.reconcileReceiveOperation(operationId)
      })
    if (!request) {
      failReceive("credential_unavailable")
      return
    }
    receiveRequest = request
  }

  function withReceiveOperation(values, operation) {
    var result = []
    var replaced = false
    var source = Array.isArray(values) ? values : []
    for (var i = 0; i < source.length; i++) {
      if (String(source[i].id || "") === String(operation.id || "")) {
        if (["finalized", "rolled_back"].indexOf(String(operation.state || "")) === -1)
          result.push(operation)
        replaced = true
      } else result.push(source[i])
    }
    if (!replaced && ["finalized", "rolled_back"].indexOf(
        String(operation.state || "")) === -1) result.push(operation)
    return result
  }

  function canonicalPreparedReceive(operationId) {
    var selected = String(operationId || "")
    var operations = Array.isArray(receiveOperations) ? receiveOperations : []
    for (var index = 0; selected && index < operations.length; index++)
      if (String(operations[index].id || "") === selected
          && String(operations[index].state || "") === "prepared")
        return operations[index]
    return null
  }

  function firstCanonicalPreparedReceive() {
    var operations = Array.isArray(receiveOperations) ? receiveOperations : []
    for (var index = 0; index < operations.length; index++)
      if (String(operations[index].state || "") === "prepared")
        return operations[index]
    return null
  }

  function reconcileReceiveOperation(operationId) {
    if (!operationId || receiveState !== "reconciling") return
    receiveReconcileToken++
    var reconcileToken = receiveReconcileToken
    abortRequests(receiveReconcileRequests)
    receiveReconcileRequests = []
    var operationValue = null
    var balancesValue = null
    var pending = 2
    var requests = []
    function accept(request, result, kind) {
      if (reconcileToken !== root.receiveReconcileToken
          || requests.indexOf(request) === -1) return
      if (!result.ok) {
        root.receiveReconcileRequests = []
        root.abortRequests(requests)
        root.failReceive(result.error.code)
        return
      }
      if (kind === "operation") {
        if (result.status !== 200 || !root.isReceiveOperation(result.value)) {
          root.failReceive("invalid_response")
          return
        }
        operationValue = result.value
      } else {
        if (result.status !== 200 || !root.isBalanceCollection(result.value)) {
          root.failReceive("invalid_response")
          return
        }
        balancesValue = result.value
      }
      pending--
      if (pending !== 0) return
      root.receiveReconcileRequests = []
      root.receiveOperations = root.withReceiveOperation(
        root.receiveOperations, operationValue)
      root.balancesResource = balancesValue
      root.refreshCount++
      if (String(operationValue.state) === "finalized") {
        root.receiveState = "success"
        root.receiveError = ""
      } else if (String(operationValue.state) === "rolled_back") {
        root.failReceive("operation_conflict")
      }
    }
    var operationRequest = sendRequest("GET", "/v1/operations/receive/"
      + encodeURIComponent(operationId), undefined, function(result) {
        accept(operationRequest, result, "operation")
      })
    var balancesRequest = sendRequest("GET", "/v1/balances", undefined,
      function(result) { accept(balancesRequest, result, "balances") })
    if (!operationRequest || !balancesRequest) {
      if (operationRequest) operationRequest.abort()
      if (balancesRequest) balancesRequest.abort()
      failReceive("credential_unavailable")
      return
    }
    requests = [operationRequest, balancesRequest]
    receiveReconcileRequests = requests
  }

  function failReceive(code, preserveAmbiguousCreation) {
    receiveReconcileToken++
    abortRequests(receiveReconcileRequests)
    receiveReconcileRequests = []
    receiveRequest = null
    receiveState = "error"
    receiveError = receiveErrorMessage(code)
    receiveOperationId = ""
    if (preserveAmbiguousCreation !== true) receiveAmbiguousCreation = null
  }

  function receiveErrorMessage(code) {
    var messages = {
      unsupported_behavior: "Only sat-denominated Cashu tokens are supported.",
      coco_error: "cocod could not prepare this Receive. Only tokens from a previously Trusted Mint can be reviewed.",
      operation_not_found: "This Receive is no longer available. Canonical Wallet state was refreshed.",
      operation_conflict: "This Receive conflicts with another Wallet operation. Try again.",
      credential_unavailable: "The cocod Client Credential is unavailable.",
      invalid_response: "cocod returned an invalid Receive response.",
      transport_unavailable: "Receive could not reach cocod. Try again."
    }
    return messages[String(code || "")] || "Receive could not be completed. Try again."
  }

  function createWallet() {
    if (creating || createRequest || connectionState !== "connected"
        || compatibilityState !== "compatible" || walletState !== "uninitialized") return false
    createSettlementTimer.stop()
    createSettlementAttempts = 0
    createError = ""
    creating = true
    var request = sendRequest("POST", "/v1/admin/wallet/initialize", {}, function(result) {
      if (request !== root.createRequest) return
      root.createRequest = null
      if (result.ok) {
        if (result.value && typeof result.value.generatedMnemonic === "string")
          result.value.generatedMnemonic = ""
        root.fetchAllCanonicalResources(true)
        return
      }
      root.creating = false
      root.createSettlementTimer.stop()
      root.createSettlementAttempts = 0
      root.lastErrorCode = result.error.code
      if (result.error.code === "wallet_already_configured") {
        root.createError = "A Wallet Instance already exists"
        root.fetchAllCanonicalResources(true)
      } else {
        root.createError = "Wallet creation failed"
      }
    })
    if (!request) {
      creating = false
      handleCredentialUnavailable()
      return false
    }
    createRequest = request
    return true
  }

  function revealRecoveryPhrase() {
    if (recoveryRevealRequest || connectionState !== "connected"
        || compatibilityState !== "compatible" || walletState !== "unlocked") return false
    var request = sendRequest("POST", "/v1/admin/wallet/recovery-material", {}, function(result) {
      if (request !== root.recoveryRevealRequest) return
      root.recoveryRevealRequest = null
      if (!result.ok) {
        root.lastErrorCode = result.error.code
        root.recoveryPhraseRevealFailed("Recovery Phrase could not be revealed")
        return
      }
      if (!result.value || typeof result.value.mnemonic !== "string"
          || result.value.mnemonic.length === 0) {
        root.recoveryPhraseRevealFailed("cocod returned an invalid Recovery Material response")
        return
      }
      var phrase = result.value.mnemonic
      result.value.mnemonic = ""
      root.recoveryPhraseRevealed(phrase)
      phrase = ""
    })
    if (!request) {
      handleCredentialUnavailable()
      return false
    }
    recoveryRevealRequest = request
    return true
  }

  function cancelRecoveryPhraseReveal() {
    var request = recoveryRevealRequest
    recoveryRevealRequest = null
    if (request) request.abort()
  }

  function fetchBalances() {
    if (fullFetchInProgress || sendCanonicalMutationBusy()) {
      queuedBalanceInvalidation = true
      return
    }
    var previous = balanceRequest
    balanceRequest = null
    if (previous) previous.abort()
    var request = sendRequest("GET", "/v1/balances", undefined, function(result) {
      if (request !== root.balanceRequest) return
      root.balanceRequest = null
      if (!result.ok) {
        root.handleFetchFailure(result)
        return
      }
      if (!root.isBalanceCollection(result.value)) {
        root.handleContractFailure("invalid_balances", "cocod returned invalid balances")
        return
      }
      root.balancesResource = result.value
      root.refreshCount++
    })
    if (!request) {
      handleCredentialUnavailable()
      return
    }
    balanceRequest = request
  }

  function fetchMints() {
    var previous = mintRequest
    mintRequest = null
    if (previous) previous.abort()
    var request = sendRequest("GET", "/v1/mints", undefined, function(result) {
      if (request !== root.mintRequest) return
      root.mintRequest = null
      if (!result.ok) {
        root.handleFetchFailure(result)
        return
      }
      if (!root.isMintCollection(result.value)) {
        root.handleContractFailure("invalid_mints", "cocod returned invalid Known Mints")
        return
      }
      root.mintsResource = result.value
      root.refreshCount++
    })
    if (!request) {
      handleCredentialUnavailable()
      return
    }
    mintRequest = request
  }

  function fetchOperationGroup(type) {
    if (type === "send" && (fullFetchInProgress || sendCanonicalMutationBusy())) {
      queuedSendInvalidation = true
      return
    }
    var existing = type === "receive" ? receiveRequests : sendRequests
    abortRequests(existing)
    if (type === "receive") receiveRequests = []
    else sendRequests = []
    var paths = [
      "/v1/operations/" + type + "/prepared",
      "/v1/operations/" + type + "/in-flight"
    ]
    var values = []
    var pending = paths.length
    var requests = []
    for (var i = 0; i < paths.length; i++) {
      (function(index) {
        var request = root.sendRequest("GET", paths[index], undefined, function(result) {
          if (requests.indexOf(request) === -1) return
          if (!result.ok) {
            root.handleFetchFailure(result)
            return
          }
          if (!root.isOperationCollection(result.value, type)) {
            root.handleContractFailure("invalid_" + type + "_operations",
              "cocod returned invalid Operation resources")
            return
          }
          values[index] = result.value.items
          pending--
          if (pending === 0) {
            if (type === "receive") {
              root.receiveRequests = []
              root.receiveOperations = values[0].concat(values[1])
            } else {
              root.sendRequests = []
              root.sendOperations = values[0].concat(values[1])
            }
            root.refreshCount++
          }
        })
        if (!request) {
          root.handleCredentialUnavailable()
          return
        }
        requests.push(request)
      })(i)
    }
    if (type === "receive") receiveRequests = requests
    else sendRequests = requests
  }

  function withSendOperation(values, operation) {
    var result = []
    var source = Array.isArray(values) ? values : []
    var activeStates = ["init", "prepared", "executing", "pending", "rolling_back"]
    var active = operation && activeStates.indexOf(String(operation.state || "")) !== -1
    var found = false
    for (var i = 0; i < source.length; i++) {
      if (String(source[i].id || "") === String(operation.id || "")) {
        found = true
        if (active) result.push(operation)
      } else result.push(source[i])
    }
    if (!found && active) result.push(operation)
    return result
  }

  function withoutSendOperation(values, operationId) {
    var result = []
    var source = Array.isArray(values) ? values : []
    for (var i = 0; i < source.length; i++)
      if (String(source[i].id || "") !== String(operationId || ""))
        result.push(source[i])
    return result
  }

  function queueSendOperationInvalidation(operationId) {
    var id = String(operationId || "")
    if (!id) return
    var queued = ({})
    for (var key in queuedSendOperationInvalidations)
      queued[key] = true
    queued[id] = true
    queuedSendOperationInvalidations = queued
  }

  function refetchSendOperation(operationId) {
    var id = String(operationId || "")
    if (!id) return
    if (fullFetchInProgress || sendCanonicalMutationBusy()) {
      queueSendOperationInvalidation(id)
      return
    }
    if (sendLookupRequestsById[id]) {
      queueSendOperationInvalidation(id)
      return
    }

    function complete(operation, remove) {
      var requests = ({})
      for (var key in root.sendLookupRequestsById)
        if (key !== id) requests[key] = root.sendLookupRequestsById[key]
      root.sendLookupRequestsById = requests
      if (operation) root.sendOperations = root.withSendOperation(
        root.sendOperations, operation)
      else if (remove) root.sendOperations = root.withoutSendOperation(
        root.sendOperations, id)
      root.fetchBalances()
      root.refreshCount++
      if (root.queuedSendOperationInvalidations[id]) {
        var queued = ({})
        for (var queuedId in root.queuedSendOperationInvalidations)
          if (queuedId !== id) queued[queuedId] = true
        root.queuedSendOperationInvalidations = queued
        Qt.callLater(function() { root.refetchSendOperation(id) })
      }
    }

    var lookup = sendRequest("GET", "/v1/operations/send/"
      + encodeURIComponent(id), undefined, function(result) {
        if (root.sendLookupRequestsById[id] !== lookup) return
        if (!result.ok) {
          complete(null, result.error.code === "operation_not_found")
          return
        }
        if (result.status !== 200 || !root.isSendOperation(result.value)) {
          complete(null)
          root.handleContractFailure("invalid_send_operation",
            "cocod returned an invalid Send Operation")
          return
        }
        var canonical = result.value
        var refresh = root.sendRequest("POST", "/v1/operations/send/"
          + encodeURIComponent(id) + "/refresh", undefined, function(refreshResult) {
            if (root.sendLookupRequestsById[id] !== refresh) return
            if (!refreshResult.ok) {
              if (refreshResult.error.code === "operation_not_found")
                complete(null, true)
              else complete(canonical)
              if (String(root.sendOperationId || "") === id)
                root.failSend(refreshResult.error.code)
              return
            }
            if (refreshResult.status !== 200
                || !root.isSendOperation(refreshResult.value)) {
              complete(canonical)
              root.handleContractFailure("invalid_send_operation",
                "cocod returned an invalid refreshed Send Operation")
              return
            }
            complete(refreshResult.value)
          })
        if (!refresh) {
          complete(canonical)
          root.handleCredentialUnavailable()
          return
        }
        var requests = ({})
        for (var key in root.sendLookupRequestsById)
          requests[key] = root.sendLookupRequestsById[key]
        requests[id] = refresh
        root.sendLookupRequestsById = requests
      })
    if (!lookup) {
      handleCredentialUnavailable()
      return
    }
    var requests = ({})
    for (var key in sendLookupRequestsById)
      requests[key] = sendLookupRequestsById[key]
    requests[id] = lookup
    sendLookupRequestsById = requests
  }

  function refetchPendingSendOperations() {
    var operations = Array.isArray(sendOperations) ? sendOperations : []
    for (var i = 0; i < operations.length; i++) {
      var operation = operations[i]
      if (operation && String(operation.state || "") === "pending")
        refetchSendOperation(operation.id)
    }
  }

  function withoutReceiveOperation(operationId) {
    var result = []
    for (var i = 0; i < receiveOperations.length; i++)
      if (String(receiveOperations[i].id || "") !== String(operationId || ""))
        result.push(receiveOperations[i])
    return result
  }

  function nextReceiveLookupToken(operationId) {
    var tokens = ({})
    for (var key in receiveLookupTokens) tokens[key] = receiveLookupTokens[key]
    var token = Number(tokens[operationId] || 0) + 1
    tokens[operationId] = token
    receiveLookupTokens = tokens
    return token
  }

  function receiveLookupIsCurrent(operationId, token, generation) {
    return generation === receiveResourceGeneration
      && Number(receiveLookupTokens[operationId] || 0) === token
  }

  function refetchReceiveOperation(operationId) {
    var id = String(operationId || "")
    if (!id) return
    var localCommand = id === receiveOperationId
      && ["preparing", "executing", "reconciling"].indexOf(receiveState) !== -1
    var existingOperation = null
    for (var existingIndex = 0; existingIndex < receiveOperations.length;
        existingIndex++)
      if (String(receiveOperations[existingIndex].id || "") === id)
        existingOperation = receiveOperations[existingIndex]
    reconcileCanonicalReceive({
      operationId: id,
      generation: receiveResourceGeneration,
      fallback: existingOperation,
      trackRecovery: !localCommand,
      fullFetch: false
    }, function(result) {
      if (result.operation) root.receiveOperations = root.withReceiveOperation(
        root.receiveOperations, result.operation)
      else root.receiveOperations = root.withoutReceiveOperation(id)
      root.fetchBalances()
      root.refreshCount++
    })
  }

  function stopStream() {
    var request = streamRequest
    streamRequest = null
    streamOffset = 0
    streamBuffer = ""
    streamCharacters = 0
    if (request) {
      request.onreadystatechange = null
      request.abort()
    }
  }

  function startStream() {
    stopStream()
    var credential = clientCredential()
    if (!credential) {
      handleCredentialUnavailable()
      return
    }
    var request = new XMLHttpRequest()
    streamRequest = request
    request.onreadystatechange = function() {
      if (request !== root.streamRequest) return
      if (request.readyState === XMLHttpRequest.LOADING
          || request.readyState === XMLHttpRequest.DONE)
        root.consumeStreamText(request.responseText || "")
      if (request.readyState === XMLHttpRequest.DONE && request === root.streamRequest) {
        root.streamRequest = null
        root.handleStreamFailure(request.status)
      }
    }
    request.open("GET", daemonBaseUrl + "/v1/events", true)
    request.setRequestHeader("Accept", "text/event-stream")
    request.setRequestHeader("Authorization", "Bearer " + credential)
    request.send()
    heartbeatTimer.restart()
    rotationTimer.restart()
  }

  function consumeStreamText(cumulativeText) {
    if (cumulativeText.length < streamOffset) {
      streamOffset = 0
      streamBuffer = ""
    }
    var suffix = cumulativeText.slice(streamOffset)
    if (!suffix) return
    streamOffset = cumulativeText.length
    streamCharacters = cumulativeText.length
    streamBuffer += suffix.replace(/\r\n/g, "\n").replace(/\r/g, "\n")
    heartbeatTimer.restart()
    var boundary = streamBuffer.indexOf("\n\n")
    while (boundary !== -1) {
      var frame = streamBuffer.slice(0, boundary)
      streamBuffer = streamBuffer.slice(boundary + 2)
      consumeFrame(frame)
      boundary = streamBuffer.indexOf("\n\n")
    }
    if (streamOffset >= streamMaximumCharacters) rotateStream()
  }

  function consumeFrame(frame) {
    if (!frame) return
    var lines = frame.split("\n")
    var dataLines = []
    var commentOnly = true
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("retry:") === 0) {
        var retry = Number(line.slice(6).trim())
        if (isFinite(retry) && retry >= 250 && retry <= 60000) serverRetryMs = retry
      } else if (line.indexOf("data:") === 0) {
        dataLines.push(line.slice(5).trim())
        commentOnly = false
      } else if (line.charAt(0) !== ":") {
        commentOnly = false
      }
    }
    if (dataLines.length === 0) {
      if (commentOnly || frame.indexOf(":") !== -1) heartbeatCount++
      return
    }
    var event
    try {
      event = JSON.parse(dataLines.join("\n"))
    } catch (error) {
      handleContractFailure("invalid_event", "cocod sent malformed invalidation metadata")
      return
    }
    if (!isSafeInvalidation(event)) {
      handleContractFailure("invalid_event", "cocod sent unsafe invalidation metadata")
      return
    }
    if (event.type === "balance.updated") {
      fetchBalances()
      refetchPendingSendOperations()
    }
    else if (event.type === "mint.updated") fetchMints()
    else if (event.type === "operation.updated") {
      var operationType = String(event.data.operationType || "")
      if (operationType === "receive") {
        var operationId = String(event.data.operationId || "")
        if (fullFetchInProgress) {
          var queued = ({})
          for (var queuedId in queuedReceiveInvalidations)
            queued[queuedId] = true
          if (operationId) queued[operationId] = true
          queuedReceiveInvalidations = queued
        } else refetchReceiveOperation(operationId)
      } else if (operationType === "send") {
        var sendOperationId = String(event.data.operationId || "")
        if (fullFetchInProgress || sendCanonicalMutationBusy()) {
          queueSendOperationInvalidation(sendOperationId)
          queuedSendInvalidation = true
          queuedBalanceInvalidation = true
        } else refetchSendOperation(sendOperationId)
      }
      if (operationType === "receive" && receiveState === "reconciling"
          && String(event.data.operationId || "") === receiveOperationId)
        reconcileReceiveOperation(receiveOperationId)
    }
  }

  function isSafeInvalidation(event) {
    if (!event || typeof event !== "object" || typeof event.type !== "string"
        || typeof event.timestamp !== "string" || !event.data
        || containsSensitiveKey(event)) return false
    var allowed = ["history.updated", "operation.updated", "quote.updated",
      "mint.updated", "balance.updated"]
    if (allowed.indexOf(event.type) === -1) return false
    if (event.type === "operation.updated")
      return ["receive", "send"].indexOf(String(event.data.operationType || "")) !== -1
    return true
  }

  function handleStreamFailure(status) {
    heartbeatTimer.stop()
    rotationTimer.stop()
    connectionState = "unavailable"
    connectionDetail = status > 0
      ? "cocod event stream closed with HTTP " + status
      : "cocod event stream disconnected"
    lastErrorCode = "event_stream_disconnected"
    scheduleReconnect(true)
  }

  function scheduleReconnect(useServerRetry, preserveHealthyStream) {
    if (!preserveHealthyStream) stopStream()
    retryAttempt++
    var exponential = Math.min(reconnectMaximumMs,
      reconnectBaseMs * Math.pow(2, Math.max(0, retryAttempt - 1)))
    retryDelayMs = useServerRetry ? Math.max(exponential, serverRetryMs) : exponential
    reconnectTimer.interval = retryDelayMs
    reconnectTimer.restart()
  }

  function rotateStream() {
    if (!streamRequest) return
    rotationTimer.stop()
    rotationCount++
    beginReconcile("rotation")
  }

  function reconnectNow() {
    retryAttempt = 0
    retryDelayMs = 0
    beginReconcile("manual")
  }

  function refreshCanonicalResources(reason) {
    beginReconcile(String(reason || "manual"))
    return true
  }

  function retryConnection() {
    reconnectNow()
  }

  function smokeClickBar(screenName) {
    if (!shell || !shell.bar || typeof shell.bar.moduleWidgets !== "function") return "no-bar"
    var widgets = shell.bar.moduleWidgets(pluginId)
    for (var i = 0; i < widgets.length; i++) {
      var widget = widgets[i]
      var window = typeof shell.bar.targetWindow === "function"
        ? shell.bar.targetWindow(widget) : null
      var candidate = window && window.screen ? String(window.screen.name || "") : ""
      if ((!screenName || candidate === screenName)
          && typeof widget.smokeLeftClick === "function") {
        widget.smokeLeftClick()
        return candidate
      }
    }
    return "not-found"
  }

  FileView {
    id: credentialFile
    path: root.credentialPath
    preload: false
    blockAllReads: true
    printErrors: false
  }

  Timer {
    id: reconnectTimer
    repeat: false
    onTriggered: root.beginReconcile("backoff")
  }

  Timer {
    id: createSettlementTimer
    interval: 250
    repeat: false
    onTriggered: {
      if (root.creating) root.fetchAllCanonicalResources(true)
    }
  }

  Timer {
    id: rotationTimer
    interval: root.streamRotationMs
    repeat: false
    onTriggered: root.rotateStream()
  }

  Timer {
    id: heartbeatTimer
    interval: root.heartbeatTimeoutMs
    repeat: false
    onTriggered: {
      root.connectionState = "unavailable"
      root.connectionDetail = "cocod event stream heartbeat timed out"
      root.lastErrorCode = "event_stream_timeout"
      root.scheduleReconnect(true)
    }
  }

  onSendOperationsChanged: reconcileFocusedPreparedSend()

  Component.onCompleted: Qt.callLater(function() { root.beginReconcile("startup") })
  Component.onDestruction: {
    fullFetchToken++
    abortCanonicalRequests()
    if (balanceRequest) balanceRequest.abort()
    if (mintRequest) mintRequest.abort()
    abortRequests(receiveRequests)
    abortRequests(sendRequests)
    for (var sendLookupId in sendLookupRequestsById)
      if (sendLookupRequestsById[sendLookupId])
        sendLookupRequestsById[sendLookupId].abort()
    sendLookupRequestsById = ({})
    var sendCommand = sendCommandRequest
    sendCommandRequest = null
    if (sendCommand) sendCommand.abort()
    abortRequests(sendReconcileRequests)
    sendReconcileRequests = []
    receiveReconcileToken++
    abortRequests(receiveReconcileRequests)
    receiveReconcileRequests = []
    var receiveCommand = receiveRequest
    receiveRequest = null
    if (receiveCommand) receiveCommand.abort()
    var command = createRequest
    createRequest = null
    creating = false
    createSettlementTimer.stop()
    if (command) command.abort()
    cancelRecoveryPhraseReveal()
    stopStream()
  }

  IpcHandler {
    target: root.diagnosticsTarget

    function snapshot(): string {
      return root.snapshotJson()
    }

    function reconnect(): string {
      root.reconnectNow()
      return "ok"
    }

    function rotate(): string {
      root.rotateStream()
      return "ok"
    }

    function clickBar(screenName: string): string {
      return root.smokeClickBar(screenName)
    }

    function panelOpen(): string {
      return root.shell && typeof root.shell.isPluginOpen === "function"
        && root.shell.isPluginOpen(root.pluginId) ? "true" : "false"
    }
  }
}
