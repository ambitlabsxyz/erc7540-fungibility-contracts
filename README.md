# ERC-7540 Fungibility

`ERC7540Fungibility` wraps pending [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) asynchronous vault requests as fungible [ERC-6909](https://eips.ethereum.org/EIPS/eip-6909) claim tokens. Each wrapped request becomes a token ID whose balance represents a share of the pending assets (for deposits) or shares (for redeems), and whose holders can transfer, split, or partially claim against the underlying vault request.

## Motivation

ERC-7540 vaults split deposits and withdrawals into two phases: a user submits a request, waits for the vault to fulfil it, and then claims the result. While a request is pending, the claim on the settled output is bound to a single `controller` address on the vault. This makes the position illiquid: it cannot be split, composed with other protocols, or transferred without cooperation from the vault operator.

This protocol turns that opaque, single-owner claim into a fungible ERC-6909 token that:

- can be transferred and divided like any other token,
- is backed 1:1 by an isolated vault request held in a dedicated delegate contract,
- settles directly against the underlying vault when the request is fulfilled,
- can be cancelled (while still whole and pending) by returning the request to a controller the owner chooses.

## How it works

Each wrapped request is represented by a `Token` record:

```solidity
struct Token {
  uint256 tokenId;
  address owner;
  address vault;
  Kind kind;        // Deposit or Redeem
  uint256 requestId;
}
```

When a token is minted, the protocol deterministically deploys a **delegate** clone (see `@ambitlabs/delegate-contracts`) keyed by the token ID. That delegate — and only that delegate — is the controller of the underlying vault request. The delegate is isolated per token, so requests never share balances, approvals, or lifecycle state.

The ERC-6909 balance for a token ID reflects the owner's share of that single vault request. Transfers of the ERC-6909 balance do not touch the vault; they simply reassign ownership of the future claim.

## Entry points

The protocol offers four ways to mint a wrapped request and two ways to exit:

### Wrapping an existing pending request ([ERC-8161](./src/interfaces/IERC8161DepositTransferable.sol))

`transferDeposit` / `transferRedeem` take an existing pending request on an [ERC-8161](./src/interfaces/IERC8161DepositTransferable.sol)-compatible vault, transfer control of that request from its current controller to a fresh delegate, and mint ERC-6909 tokens to the receiver. The vault must implement `IERC7540Deposit` + `IERC8161DepositTransferable` (or the redeem equivalents).

### Originating a new request

`requestDeposit` pulls assets from the owner, deploys a delegate, deposits into the vault through the delegate, and mints ERC-6909 tokens to the receiver. `requestRedeem` does the same for vault shares. These paths do not require ERC-8161 support on the vault — only standard ERC-7540.

### Exiting

- `cancel(tokenId, controller)` — returns the pending vault request to a chosen controller via ERC-8161 and burns the ERC-6909 supply. Only permitted while the request is still pending and the owner holds the entire supply.
- `redeem(tokenId, shares, receiver, owner)` — once the vault has fulfilled the request, burns `shares` of the ERC-6909 token and claims the corresponding portion from the vault (`deposit` for wrapped deposit requests, `redeem` for wrapped redeem requests). The claim is executed via the delegate and delivered directly to `receiver`. Partial claims are supported.

## Authorization

Authorization follows the ERC-7540 operator pattern via `isOperator` on this contract:

- Request origination and wrapping require the caller to be the `owner`/`controller` or their operator on this contract.
- Cancellation and redemption require the caller to be the token owner or their operator.
- For `transferDeposit` / `transferRedeem`, this contract must also be set as an operator on the vault for the original controller, so it can pull the pending request across via ERC-8161.

ERC-6909 balances themselves follow standard `approve` / `setOperator` / `transfer` / `transferFrom` semantics.

## Contracts

| Contract | Purpose |
|---|---|
| [`ERC7540Fungibility`](./src/ERC7540Fungibility.sol) | The fungibility contract. Implements ERC-6909, ERC-6909Metadata, ERC-6909TokenSupply, and `IERC7540Fungibility`. |
| [`IERC7540Fungibility`](./src/interfaces/IERC7540Fungibility.sol) | Public interface: wrap / originate / cancel / redeem. |
| [`IERC8161DepositTransferable`](./src/interfaces/IERC8161DepositTransferable.sol) | Required on vaults to transfer in existing pending deposit requests. |
| [`IERC8161RedeemTransferable`](./src/interfaces/IERC8161RedeemTransferable.sol) | Required on vaults to transfer in existing pending redeem requests. |

## Build

```
forge build
```
