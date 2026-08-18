import QtQuick
import Quickshell
import Quickshell.Io

// The Shell Adapter is the only transport-owning module. Bar and panel callers
// consume the domain properties below and never see URLs, XHR, SSE frames,
// retry timers, or contract reconciliation.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.egge21m.omarchy-cashu"
  readonly property string diagnosticsTarget: pluginId + ".state"
  property string daemonBaseUrl: {
    var configured = Quickshell.env("OMARCHY_CASHU_DAEMON_URL")
    return configured ? String(configured).replace(/\/$/, "") : "http://127.0.0.1:38421"
  }
  readonly property bool daemonUrlAllowed: isLoopbackBaseUrl(daemonBaseUrl)
  property int reconnectBaseMs: 250
  property int reconnectMaximumMs: 4000
  property int streamRotationMs: 30000
  property int streamMaximumCharacters: 32768
  property int heartbeatTimeoutMs: 3000

  property var walletSnapshot: ({
    apiVersion: "1",
    revision: 0,
    wallet: {
      state: "unavailable",
      detail: "Waiting for cocod",
      balances: { spendable: 0, reserved: 0, unit: "sat" },
      activeTransfers: []
    }
  })
  property string connectionState: "connecting"
  property string compatibilityState: "unknown"
  property string connectionDetail: "Connecting to cocod on loopback"
  property int retryAttempt: 0
  property int retryDelayMs: 0
  property int observedRevision: 0
  property int streamCharacters: 0
  property int heartbeatCount: 0
  property int rotationCount: 0
  property int reconnectCount: 0
  property var snapshotRequest: null
  property bool connectStreamAfterSnapshot: false
  property var streamRequest: null
  property int streamOffset: 0
  property string streamBuffer: ""

  readonly property int revision: Number(walletSnapshot.revision || 0)
  readonly property bool fixtureBacked: false
  readonly property var daemonWallet: walletSnapshot.wallet || ({})
  readonly property string daemonWalletState: String(daemonWallet.state || "unavailable")
  readonly property string walletState: connectionState === "connected"
    ? daemonWalletState : "unavailable"
  readonly property string walletStateLabel: stateLabel(walletState)
  readonly property string walletStateDetail: connectionState === "connected"
    ? String(daemonWallet.detail || "Wallet Instance") : connectionDetail
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
  readonly property var balances: daemonWallet.balances || ({})
  readonly property bool balancesAvailable: connectionState === "connected"
    && compatibilityState === "compatible"
  readonly property int spendableBalance: balancesAvailable
    ? Number(balances.spendable || 0) : 0
  readonly property int reservedBalance: balancesAvailable
    ? Number(balances.reserved || 0) : 0
  readonly property string unit: String(balances.unit || "sat")
  readonly property var activeTransfers: Array.isArray(daemonWallet.activeTransfers)
    ? daemonWallet.activeTransfers : []
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

  function setupView() {
    if (!daemonUrlAllowed) return {
      title: "Invalid cocod connection",
      detail: "Use an HTTP endpoint on 127.0.0.1, localhost, or ::1."
    }
    if (compatibilityState === "incompatible") return {
      title: "Incompatible cocod contract",
      detail: "Install a cocod version that supports Wallet Client contract v1."
    }
    if (connectionState === "missing") return {
      title: "cocod is not available",
      detail: "Start the Slice 2 mock cocod on 127.0.0.1:38421."
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
      detail: retryDelayMs > 0 ? "Next attempt in " + retryDelayMs + " ms." : "Fetching Wallet State."
    }
    return {
      title: "Connected to cocod",
      detail: "Live Wallet State · contract v" + walletSnapshot.apiVersion
    }
  }

  function snapshot() {
    return {
      apiVersion: String(walletSnapshot.apiVersion || ""),
      daemonUrlAllowed: daemonUrlAllowed,
      revision: revision,
      observedRevision: observedRevision,
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
      connectionState: connectionState,
      compatibilityState: compatibilityState,
      connectionDetail: connectionDetail,
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

  function beginReconcile(reason) {
    reconnectTimer.stop()
    heartbeatTimer.stop()
    rotationTimer.stop()
    stopStream()
    if (!daemonUrlAllowed) {
      compatibilityState = "unknown"
      connectionState = "error"
      connectionDetail = "cocod URL must use HTTP on loopback"
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
      connectionDetail = "Refreshing authoritative Wallet State"
    }
    fetchSnapshot(true)
  }

  function stopStream() {
    var request = streamRequest
    streamRequest = null
    streamOffset = 0
    streamBuffer = ""
    if (request) request.abort()
  }

  function fetchSnapshot(connectAfterward) {
    if (connectAfterward) connectStreamAfterSnapshot = true
    if (snapshotRequest) return
    var request = new XMLHttpRequest()
    snapshotRequest = request
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE || request !== root.snapshotRequest) return
      root.snapshotRequest = null
      var shouldConnectStream = root.connectStreamAfterSnapshot
      root.connectStreamAfterSnapshot = false
      if (request.status !== 200) {
        root.handleSnapshotFailure(request.status)
        return
      }
      var value
      try {
        value = JSON.parse(request.responseText)
      } catch (error) {
        root.handleContractError("cocod returned malformed JSON")
        return
      }
      if (!root.isSnapshotShape(value)) {
        root.handleContractError("cocod returned an invalid snapshot")
        return
      }
      if (String(value.apiVersion) !== "1") {
        root.compatibilityState = "incompatible"
        root.connectionState = "error"
        root.connectionDetail = "Contract v" + value.apiVersion + " is not supported"
        root.stopStream()
        return
      }
      if (Number(value.revision) < observedRevision) {
        root.handleContractError("cocod returned a stale snapshot revision")
        return
      }
      root.compatibilityState = "compatible"
      root.walletSnapshot = value
      root.observedRevision = Math.max(root.observedRevision, Number(value.revision))
      root.connectionState = "connected"
      root.connectionDetail = "Connected to cocod"
      root.retryAttempt = 0
      root.retryDelayMs = 0
      if (shouldConnectStream) root.startStream()
    }
    request.open("GET", daemonBaseUrl + "/v1/wallet/snapshot", true)
    request.setRequestHeader("Accept", "application/json")
    request.send()
  }

  function isSnapshotShape(value) {
    if (!value || typeof value !== "object" || !value.wallet) return false
    if (!isFinite(Number(value.revision)) || Number(value.revision) < 0) return false
    var wallet = value.wallet
    var balance = wallet.balances
    return typeof wallet.state === "string" && balance
      && isFinite(Number(balance.spendable)) && isFinite(Number(balance.reserved))
      && String(balance.unit || "") === "sat"
      && Array.isArray(wallet.activeTransfers)
  }

  function handleSnapshotFailure(status) {
    compatibilityState = "unknown"
    connectionState = status === 0 && revision === 0 ? "missing" : "unavailable"
    connectionDetail = status > 0
      ? "cocod snapshot request failed with HTTP " + status
      : "No compatible cocod is listening on loopback"
    scheduleReconnect()
  }

  function handleContractError(detail) {
    compatibilityState = "unknown"
    connectionState = "error"
    connectionDetail = detail
    stopStream()
    scheduleReconnect()
  }

  function startStream() {
    stopStream()
    var request = new XMLHttpRequest()
    streamRequest = request
    streamOffset = 0
    streamBuffer = ""
    request.onreadystatechange = function() {
      if (request !== root.streamRequest) return
      if (request.readyState === XMLHttpRequest.LOADING
          || request.readyState === XMLHttpRequest.DONE) {
        root.consumeStreamText(request.responseText || "")
      }
      if (request.readyState === XMLHttpRequest.DONE && request === root.streamRequest) {
        root.streamRequest = null
        root.handleStreamFailure(request.status)
      }
    }
    request.open("GET", daemonBaseUrl + "/v1/events", true)
    request.setRequestHeader("Accept", "text/event-stream")
    if (revision > 0) request.setRequestHeader("Last-Event-ID", String(revision))
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
    if (!frame || frame.charAt(0) === ":") {
      heartbeatCount++
      return
    }
    var lines = frame.split("\n")
    var eventName = "message"
    var eventId = ""
    var dataLines = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("event:") === 0) eventName = line.slice(6).trim()
      else if (line.indexOf("id:") === 0) eventId = line.slice(3).trim()
      else if (line.indexOf("data:") === 0) dataLines.push(line.slice(5).trim())
    }
    if (eventName !== "wallet.changed" || dataLines.length === 0) return
    var metadata
    try {
      metadata = JSON.parse(dataLines.join("\n"))
    } catch (error) {
      handleContractError("cocod sent malformed lifecycle metadata")
      return
    }
    if (!safeLifecycleMetadata(metadata)) {
      handleContractError("cocod sent unsafe lifecycle metadata")
      return
    }
    var eventRevision = Number(metadata.revision || eventId || 0)
    if (eventId && Number(eventId) !== eventRevision) {
      handleContractError("cocod sent mismatched lifecycle revisions")
      return
    }
    if (eventRevision <= observedRevision) return
    observedRevision = eventRevision
    fetchSnapshot(false)
  }

  function safeLifecycleMetadata(metadata) {
    if (!metadata || String(metadata.apiVersion || "") !== "1") return false
    var allowed = ["apiVersion", "revision", "kind", "transferId"]
    for (var key in metadata) if (allowed.indexOf(key) === -1) return false
    var kinds = ["wallet-state-changed", "transfer-lifecycle-changed"]
    return isFinite(Number(metadata.revision)) && Number(metadata.revision) > 0
      && kinds.indexOf(String(metadata.kind || "")) !== -1
  }

  function handleStreamFailure(status) {
    heartbeatTimer.stop()
    rotationTimer.stop()
    connectionState = "unavailable"
    connectionDetail = status > 0
      ? "cocod event stream closed with HTTP " + status
      : "cocod event stream disconnected"
    scheduleReconnect()
  }

  function scheduleReconnect() {
    stopStream()
    retryAttempt++
    retryDelayMs = Math.min(reconnectMaximumMs,
      reconnectBaseMs * Math.pow(2, Math.max(0, retryAttempt - 1)))
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
      root.scheduleReconnect()
    }
  }

  Component.onCompleted: Qt.callLater(function() { root.beginReconcile("startup") })
  Component.onDestruction: {
    var request = snapshotRequest
    snapshotRequest = null
    connectStreamAfterSnapshot = false
    if (request) request.abort()
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
