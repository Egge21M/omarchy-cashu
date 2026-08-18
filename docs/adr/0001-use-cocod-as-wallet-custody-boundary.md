# Use cocod as the wallet custody boundary

Cashu Wallet uses one dedicated `cocod` process per Wallet Instance. `cocod` is the sole custodian and system of record, while the Omarchy Wallet Client only presents state and requests operations; the daemon runs as a session-scoped systemd user service so wallet state and in-flight operations survive shell or plugin reloads without persisting beyond the user's session.
