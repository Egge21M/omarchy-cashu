# Omarchy Cashu Wallet

A desktop-native Cashu wallet for Omarchy. It gives Cashu users a clean wallet experience integrated into their operating system while a dedicated wallet service manages wallet state and operations.

## Language

**Wallet**:
The complete product through which a Cashu User views and uses their ecash. It combines the Wallet Client experience with the wallet capabilities provided by cocod.

**Wallet Instance**:
A single wallet identity and its state, owned by one cocod process and presented by the Wallet Client.
_Avoid_: Account, profile

**Wallet State**:
The current condition of a Wallet Instance as reported by cocod, determining which wallet actions are available. A Wallet may be unavailable, uninitialized, locked, unlocked, or in an error state.
_Avoid_: UI state, connection status

**Spendable Balance**:
The amount of ecash that cocod currently reports as available for a Send.
_Avoid_: Account balance, portfolio value

**Reserved Balance**:
Ecash held by an active Send and therefore unavailable for another Send.
_Avoid_: Spendable Balance, pending balance

**Recovery Phrase**:
The secret words controlled by the Cashu User for recovering a Wallet Instance. cocod retains the Recovery Phrase, and the Wallet Client reveals it only after an explicit user request.
_Avoid_: Mnemonic, seed phrase, password

**Wallet Client**:
The user-facing part of the Wallet embedded in Omarchy. It presents wallet state and requests operations from cocod without owning authoritative wallet state or retaining wallet secrets.
_Avoid_: Plugin, frontend

**cocod**:
The background wallet service that is the Wallet's sole custodian and system of record. It owns wallet state and performs Cashu operations on behalf of the Wallet Client.
_Avoid_: Wallet UI, plugin

**Cashu User**:
An Omarchy user who uses Cashu and wants a clean wallet experience integrated into their operating system.
_Avoid_: Customer, account

**Trusted Mint**:
A Cashu mint that the Cashu User has explicitly approved for wallet operations.
_Avoid_: Known mint, default mint

**Ecash Transfer**:
The movement of ecash into or out of a Wallet Instance using an encoded Cashu token.
_Avoid_: Lightning payment, transaction

**Transfer Preview**:
A non-mutating description of a proposed Ecash Transfer, including its amount, unit, mint, fees, and trust status where applicable.
_Avoid_: Prepared Transfer, quote

**Receive**:
An inbound Ecash Transfer in which the Wallet accepts and redeems an encoded Cashu token.
_Avoid_: Mint, deposit

**Prepared Receive**:
A Receive that has been previewed and approved but whose encoded Cashu token has not yet been redeemed. A Prepared Receive can be confirmed or cancelled.
_Avoid_: Pending Receive, completed Receive

**Send**:
An outbound Ecash Transfer in which the Wallet creates an encoded Cashu token for a chosen amount.
_Avoid_: Melt, withdrawal

**Prepared Send**:
A Send for which cocod has reserved ecash but has not yet created the outgoing Cashu token. A Prepared Send can be confirmed or cancelled.
_Avoid_: Draft Send, Pending Send

**Pending Send**:
A Send whose encoded Cashu token has been created but whose proofs have not all been observed as spent. cocod retains the token so the Wallet Client can present it again after interruption.
_Avoid_: Failed Send, history entry

**Reclaim**:
An attempt to return the ecash from a Pending Send to the Wallet before the recipient redeems it. A Reclaim can race with redemption and is not guaranteed to succeed.
_Avoid_: Cancel, refund

**Active Transfer**:
An Ecash Transfer whose lifecycle has not reached a terminal outcome and may still require progress, recovery, or user attention.
_Avoid_: History entry, completed transfer
