# Manage durable Sends explicitly

Beginning a new Send and managing an Active Send are separate Wallet Client actions: the primary Send action always opens fresh amount entry, while Active Sends are reopened only by their cocod Operation ID. Because cocod owns durable Operation lifecycle, closing or navigating away from the Wallet Client never cancels a Prepared Send; confirmation, cancellation, token retrieval, and Reclaim are explicit state-specific commands, allowing multiple Active Sends up to the Spendable Balance reported by cocod.

The Wallet Client serializes Send mutations for deterministic reconciliation but never blocks navigation. During a temporary disconnection it may retain the last canonical Active Sends projection in memory as read-only; it clears that projection when the daemon identity or Client Credential changes and never permits an Active Send to be hidden without a terminal cocod state.

SSE invalidations remain the fast synchronization path, supplemented by canonical collection fetches when the panel or Active Sends opens and bounded polling while the open panel contains Active Sends. A Pending Send's bearer token is fetched only after explicit Copy or Reveal intent, retained only by the focused detail view, and cleared when that view or security context closes.
