# ERC-7540 Fungibility

`ERC7540Fungibility` wraps pending [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) asynchronous vault requests as fungible [ERC-6909](https://eips.ethereum.org/EIPS/eip-6909) claim tokens. Each wrapped request becomes a token ID whose balance represents a share of the pending assets (for deposits) or shares (for redeems), and whose holders can transfer, split, or partially claim against the underlying vault request.

## Motivation

ERC-7540 vaults split deposits and withdrawals into two phases: a user submits a request, waits for the vault to fulfil it, and then claims the result. While a request is pending, the claim on the settled output is bound to a single `controller` address on the vault. This makes the position illiquid: it cannot be split, composed with other protocols, or transferred without cooperation from the vault operator.

This protocol turns that opaque, single-owner claim into a fungible ERC-6909 token that:

- can be transferred and divided like any other token,
- is backed 1:1 by an isolated vault request held in a dedicated delegate contract,
- settles directly against the underlying vault when the request is fulfilled,
- can be cancelled (while still whole and pending) by returning the request to the owner as vault-side controller.

## How it works

A `ClaimToken` (ERC-6909) contract is deployed lazily per (vault, kind) pair, where kind is either deposit or redeem. Each wrapped request is a token ID on that `ClaimToken`, recorded on the coordinator as:

```solidity
struct Request {
  address vault;
  uint256 requestId;
}
```

When a token is minted, the protocol deterministically deploys a **delegate** clone (see `@ambitlabs/delegate-contracts`) keyed by the claim token and token ID. That delegate — and only that delegate — is the controller of the underlying vault request. The delegate is isolated per token, so requests never share balances, approvals, or lifecycle state.

The ERC-6909 balance for a token ID reflects the owner's share of that single vault request. Transfers of the ERC-6909 balance do not touch the vault; they simply reassign ownership of the future claim.

## Entry points

The protocol offers four ways to mint a wrapped request and two ways to exit:

### Wrapping an existing pending request ([ERC-8161](./src/interfaces/IERC8161DepositTransferable.sol))

`transferDeposit` / `transferRedeem` take an existing pending request on an [ERC-8161](./src/interfaces/IERC8161DepositTransferable.sol)-compatible vault, transfer control of that request from the caller to a fresh delegate, and mint ERC-6909 tokens to the receiver. The caller must be the current controller of the request and must have approved this contract as an operator on the vault so the request can be pulled across via ERC-8161. The vault must implement `IERC7540Deposit` + `IERC8161DepositTransferable` (or the redeem equivalents).

### Originating a new request

`requestDeposit` pulls assets from the caller, deploys a delegate, deposits into the vault through the delegate, and mints ERC-6909 tokens to the receiver. `requestRedeem` does the same for vault shares. The caller must have approved this contract on the vault's underlying asset (or share token) for the amount being pulled. These paths do not require ERC-8161 support on the vault — only standard ERC-7540.

### Exiting

- `cancel(claimToken, tokenId)` — returns the pending vault request to the caller via ERC-8161 and burns the ERC-6909 supply. Only permitted while the request is still pending and the caller holds the entire supply.
- `deposit(claimToken, tokenId, assets, receiver)` / `redeem(claimToken, tokenId, shares, receiver)` — once the vault has fulfilled the request, burns the caller's ERC-6909 balance and claims the corresponding portion from the vault. The claim is executed via the delegate and delivered directly to `receiver`. Partial claims are supported.

## Authorization

There is no operator or delegation mechanism on this contract. Every entry point acts strictly on `msg.sender`:

- `requestDeposit` / `requestRedeem` pull assets or shares from the caller, who must have approved this contract on the relevant token.
- `transferDeposit` / `transferRedeem` require the caller to be the current controller of the vault request, and this contract must be approved as an operator on the vault for the caller so it can pull the pending request across via ERC-8161.
- `cancel`, `deposit`, and `redeem` burn the caller's own ERC-6909 balance; `cancel` returns the vault request to the caller.

A third party that wants to act on a position must hold the claim tokens itself. ERC-6909 balances follow standard `approve` / `setOperator` / `transfer` / `transferFrom` semantics on the `ClaimToken`, so delegation is done at the token layer, not on this contract.

## Contracts

| Contract | Purpose |
|---|---|
| [`ERC7540Fungibility`](./src/ERC7540Fungibility.sol) | The coordinator contract. Implements `IERC7540Fungibility`: wraps requests, deploys `ClaimToken`s and delegates, settles claims. |
| [`ClaimToken`](./src/ClaimToken.sol) | ERC-6909 claim token (with Metadata and TokenSupply extensions), cloned per (vault, kind). |
| [`IERC7540Fungibility`](./src/interfaces/IERC7540Fungibility.sol) | Public interface: wrap / originate / cancel / claim. |
| [`IERC8161DepositTransferable`](./src/interfaces/IERC8161DepositTransferable.sol) | Required on vaults to transfer in existing pending deposit requests. |
| [`IERC8161RedeemTransferable`](./src/interfaces/IERC8161RedeemTransferable.sol) | Required on vaults to transfer in existing pending redeem requests. |

## Build

```
forge build
```
