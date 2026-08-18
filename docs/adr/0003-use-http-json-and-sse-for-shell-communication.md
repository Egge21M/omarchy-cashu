# Use HTTP/JSON and SSE for shell communication

The Wallet Client uses versioned HTTP/JSON over loopback TCP for commands and authoritative snapshots, plus Server-Sent Events consumed by a shared Quickshell Shell Adapter for safe lifecycle notifications. This works in stock Omarchy with authentication headers and no WebSocket dependency, but requires manual SSE parsing, reconnection, bounded stream rotation, and an integration test because repeated streaming callbacks are supported by Qt's implementation rather than guaranteed by its public QML API.
