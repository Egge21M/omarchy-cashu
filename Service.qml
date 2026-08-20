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
  readonly property var requiredCapabilities: [
    "wallet.lifecycle",
    "wallet.balances",
    "wallet.mints",
    "wallet.receive-operations",
    "wallet.send-operations",
    "wallet.events"
  ]

  property int reconnectBaseMs: 250
  property int reconnectMaximumMs: 4000
  property int streamRotationMs: 30000
  property int streamMaximumCharacters: 32768
  property int heartbeatTimeoutMs: 20000

  property var capabilitiesResource: ({})
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
  property var canonicalRequests: []
  property var balanceRequest: null
  property var mintRequest: null
  property var receiveRequests: []
  property var sendRequests: []
  property var streamRequest: null
  property int streamOffset: 0
  property string streamBuffer: ""
  property var createRequest: null
  property bool creating: false
  property string createError: ""
  property var recoveryRevealRequest: null

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
    receiveOperations, sendOperations)
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
      detail: "Install a cocod version that supports the required Wallet capabilities."
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
      apiVersion: String(capabilitiesResource.interfaceVersion || ""),
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
      creating: creating,
      createError: createError,
      connectionState: connectionState,
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

  function operationStateLabel(operation) {
    var labels = {
      prepared: operation.type === "receive" ? "Receive ready" : "Send ready",
      executing: operation.type === "receive" ? "Receiving" : "Sending",
      pending: "Pending Send",
      rolling_back: "Reclaiming"
    }
    return labels[String(operation.state || "")] || "Active Transfer"
  }

  function composeActiveTransfers(receives, sends) {
    var result = []
    var seen = ({})
    var values = (Array.isArray(receives) ? receives : [])
      .concat(Array.isArray(sends) ? sends : [])
    for (var i = 0; i < values.length; i++) {
      var operation = values[i]
      var id = String(operation.id || "")
      if (!id || seen[id]) continue
      seen[id] = true
      result.push({
        id: id,
        type: String(operation.type || ""),
        state: String(operation.state || ""),
        stateLabel: operationStateLabel(operation),
        detail: String(operation.mintUrl || ""),
        amount: String(operation.amount || "0"),
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

  function isCapabilitiesShape(value) {
    if (!value || typeof value !== "object" || !Array.isArray(value.capabilities)) return false
    if (typeof value.instanceId !== "string" || value.instanceId.length === 0) return false
    for (var i = 0; i < requiredCapabilities.length; i++)
      if (value.capabilities.indexOf(requiredCapabilities[i]) === -1) return false
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
    for (var i = 0; i < value.items.length; i++) {
      var item = value.items[i]
      if (String(item.type || "") !== type || typeof item.id !== "string"
          || typeof item.state !== "string" || typeof item.mintUrl !== "string"
          || typeof item.unit !== "string" || !decimalString(item.amount)) return false
    }
    return true
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
    return { code: value.error.code, retryable: value.error.retryable }
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
    request.send(body === undefined ? null : JSON.stringify(body))
    return request
  }

  function abortRequests(requests) {
    var values = Array.isArray(requests) ? requests : []
    for (var i = 0; i < values.length; i++) if (values[i]) {
      values[i].onreadystatechange = null
      values[i].abort()
    }
  }

  function abortCanonicalRequests() {
    var requests = canonicalRequests
    canonicalRequests = []
    abortRequests(requests)
  }

  function beginReconcile(reason) {
    var preserveHealthyStream = !!streamRequest
      && reason !== "startup" && reason !== "rotation"
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
    if (reason === "startup") {
      connectionState = "connecting"
      connectionDetail = "Connecting to cocod on loopback"
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
    var token = ++fullFetchToken
    var capabilityRequest = sendRequest("GET", "/v1/capabilities", undefined,
      function(result) {
        if (token !== root.fullFetchToken) return
        if (!result.ok) {
          root.handleFetchFailure(result)
          return
        }
        if (!root.isCapabilitiesShape(result.value)
            || String(result.value.interfaceVersion || "") !== "1") {
          root.compatibilityState = "incompatible"
          root.connectionState = "error"
          root.connectionDetail = "Required cocod v1 capabilities are unavailable"
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

  function fetchLifecycleForBootstrap(token, capabilities, connectAfterward) {
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
        root.finishFullFetch(capabilities, result.value,
          { items: [] }, { items: [] }, [], [], connectAfterward)
        return
      }
      root.fetchWalletResources(token, capabilities, result.value, connectAfterward)
    })
    if (!request) {
      handleCredentialUnavailable()
      return
    }
    canonicalRequests.push(request)
  }

  function fetchWalletResources(token, capabilities, status, connectAfterward) {
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
            var receives = values.receivePrepared.items.concat(values.receiveInFlight.items)
            var sends = values.sendPrepared.items.concat(values.sendInFlight.items)
            root.finishFullFetch(capabilities, status, values.balances, values.mints,
              receives, sends, connectAfterward)
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

  function finishFullFetch(capabilities, status, balances, mints, receives, sends,
      connectAfterward) {
    canonicalRequests = []
    capabilitiesResource = capabilities
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
    if (walletState !== "uninitialized") {
      creating = false
      createError = ""
    }
    if (connectAfterward && walletState === "unlocked") startStream()
  }

  function handleCredentialUnavailable() {
    connectionState = "error"
    compatibilityState = "unknown"
    connectionDetail = "The cocod Client Credential is unavailable"
    lastErrorCode = "credential_unavailable"
    retryAttempt = 0
    retryDelayMs = 0
  }

  function handleFetchFailure(result) {
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
    abortCanonicalRequests()
    compatibilityState = "unknown"
    connectionState = "error"
    connectionDetail = detail
    lastErrorCode = code
    scheduleReconnect(false, false)
  }

  function createWallet() {
    if (creating || createRequest || connectionState !== "connected"
        || compatibilityState !== "compatible" || walletState !== "uninitialized") return false
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
    if (event.type === "balance.updated") fetchBalances()
    else if (event.type === "mint.updated") fetchMints()
    else if (event.type === "operation.updated")
      fetchOperationGroup(String(event.data.operationType || ""))
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
    rotationCount++
    beginReconcile("rotation")
  }

  function reconnectNow() {
    retryAttempt = 0
    retryDelayMs = 0
    beginReconcile("manual")
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

  Component.onCompleted: Qt.callLater(function() { root.beginReconcile("startup") })
  Component.onDestruction: {
    fullFetchToken++
    abortCanonicalRequests()
    if (balanceRequest) balanceRequest.abort()
    if (mintRequest) mintRequest.abort()
    abortRequests(receiveRequests)
    abortRequests(sendRequests)
    var command = createRequest
    createRequest = null
    creating = false
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
