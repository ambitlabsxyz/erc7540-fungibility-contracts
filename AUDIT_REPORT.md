# Security Audit Report — ERC-7540 Fungibility Contract

**Date**: 2026-04-17
**Auditor**: Automated Security Analysis (Claude Opus 4.6)
**Scope**: `src/ERC7540Fungibility.sol` (445 lines) + 6 interface files (402 lines)
**Language/Version**: Solidity 0.8.34
**Build Status**: Compiled successfully (Foundry, via-ir)
**Static Analysis Status**: Slither unavailable (grep fallback used); Aderyn unavailable
**Note**: Proven-only mode enabled — 5 findings capped at Low from Medium due to unproven evidence ([CODE-TRACE] only). 1 additional finding downgraded by trust assumption exclusion.

---

## Executive Summary

ERC7540Fungibility is a contract that wraps asynchronous ERC-7540 vault deposit and redeem requests into fungible ERC-6909 tokens. The design addresses a genuine problem: ERC-7540 vault positions are non-fungible request IDs, and this contract enables secondary market trading and composability by converting those positions into standardized multi-token (ERC-6909) representations. The protocol uses a delegate clone architecture — each token ID deploys a unique CREATE2 proxy (Delegate) that holds the vault position on behalf of ERC-6909 holders.

Two findings render the core deposit claim flow completely non-functional in production. H-01 (wrong function selector in `claimDeposit`) causes all deposit token redemptions to revert against any compliant ERC-7540 vault, permanently locking deposited assets. M-01 (missing share approval in `requestRedeem`) means all new redeem requests revert unconditionally. Combined, the contract cannot process new redeem requests and cannot settle existing deposit positions — effectively making the primary value flows of the protocol non-operational. These bugs are masked by the test suite because `MockVault` implements a non-standard 2-parameter `deposit` overload that compliant production vaults do not expose.

Beyond these operational blockers, the audit identified five additional Medium findings covering: TOCTOU-based supply inflation via malicious vault responses, operator token draining via unrestricted vault selection, exchange rate variation causing unequal payouts across ERC-6909 holders of the same token ID, permanent fund lock from zero-address receiver input, and cancel-time orphaning of partially-fulfilled claimable assets. Twenty-two Low findings and eight Informational observations address stale state, missing slippage protections, incorrect decimals metadata, and various edge-case fund loss scenarios — several of which are significant in composed attack paths. Immediate remediation is recommended for H-01 and M-01 before any production deployment.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 7 |
| Low | 22 |
| Informational | 8 |

### Components Audited

| Component | Path | Lines | Description |
|-----------|------|-------|-------------|
| ERC7540Fungibility | `src/ERC7540Fungibility.sol` | 445 | Main contract — wraps ERC-7540 vault requests into fungible ERC-6909 tokens |
| IERC7540Fungibility | `src/interfaces/IERC7540Fungibility.sol` | 211 | Main interface |
| IERC7540Deposit | `src/interfaces/IERC7540Deposit.sol` | 63 | ERC-7540 deposit interface |
| IERC7540Redeem | `src/interfaces/IERC7540Redeem.sol` | 42 | ERC-7540 redeem interface |
| IERC8161DepositTransferable | `src/interfaces/IERC8161DepositTransferable.sol` | 24 | ERC-8161 deposit transfer |
| IERC8161RedeemTransferable | `src/interfaces/IERC8161RedeemTransferable.sol` | 24 | ERC-8161 redeem transfer |
| IERC7540Operator | `src/interfaces/IERC7540Operator.sol` | 38 | Operator interface |

---

## High Findings

### [H-01] `claimDeposit` Uses Wrong Function Selector — Permanent Deposit Fund Lock [VERIFIED]

**Severity**: High
**Location**: `src/ERC7540Fungibility.sol:L416-L421`
**Confidence**: HIGH (6 agents confirmed, Static Analysis: N/A, PoC: PASS, Skeptic-Judge: AGREE)

**Description**:

The `claimDeposit` function encodes a call to the 2-parameter `IERC4626.deposit(uint256, address)` (selector `0x6e553f65`), but ERC-7540 compliant vaults only expose the 3-parameter `deposit(uint256, address, address)` (selector `0x2e2d2984`) as defined in the `IERC7540Deposit` interface. When the delegate forwards this call to the vault, the vault has no function matching the 2-parameter selector, causing the transaction to revert. This makes all deposit-type token claims permanently non-functional on any compliant ERC-7540 vault.

The problematic code in `claimDeposit`:

```solidity
// src/ERC7540Fungibility.sol:L416-L422
function claimDeposit(Token storage token, uint256 shares, address receiver) private returns (uint256) {
    address payable delegate = DELEGATE.predict(token.tokenId);

    bytes memory result = Delegate(delegate).call(token.vault, abi.encodeCall(IERC4626.deposit, (shares, receiver)));

    return abi.decode(result, (uint256));
}
```

The ERC-7540 standard replaces the synchronous ERC-4626 `deposit(uint256, address)` with `deposit(uint256, address, address)`, adding a mandatory `controller` parameter. The correct signature is defined in the project's own interface file:

```solidity
// src/interfaces/IERC7540Deposit.sol:L54
function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);
```

Notably, the analogous `claimRedeem` function correctly uses the 3-parameter pattern:

```solidity
// src/ERC7540Fungibility.sol:L424-L433
function claimRedeem(Token storage token, uint256 shares, address receiver) private returns (uint256) {
    address payable delegate = DELEGATE.predict(token.tokenId);

    bytes memory result = Delegate(delegate).call(
        token.vault,
        abi.encodeCall(IERC4626.redeem, (shares, receiver, delegate))
    );

    return abi.decode(result, (uint256));
}
```

This asymmetry confirms the 2-parameter call in `claimDeposit` is an implementation mistake, not a design choice. The existing test suite masks this bug because `MockVault` implements both the 2-parameter and 3-parameter `deposit` overloads, meaning tests pass against the mock but would fail against any production ERC-7540 vault.

Furthermore, the contract itself enforces that only ERC-7540 vaults are accepted at request time (L200: `requireInterface(vault, type(IERC7540Deposit).interfaceId)`), guaranteeing that every vault used with this contract will lack the 2-parameter function.

When combined with M-06 (cancel on partially-fulfilled deposits only recovers the pending portion), this bug creates a total fund lock scenario for deposit tokens that have been partially fulfilled: `redeem()` reverts due to the selector mismatch, and `cancel()` can only recover the still-pending portion while the already-claimable assets remain permanently orphaned in the delegate contract with no recovery path.

**Impact**:

- All deposited assets backing deposit-type ERC-6909 tokens are permanently locked. Users cannot claim their fulfilled deposit positions on any compliant ERC-7540 vault.
- For partially-fulfilled deposits, the situation is worse: `redeem()` reverts (this bug), and `cancel()` only returns the unfulfilled pending portion (see M-06), meaning the fulfilled/claimable portion is permanently lost with no exit path.
- The contract's entire deposit claim functionality is broken. Every user who wraps a deposit request through this contract will lose their deposited assets.

**PoC Result**:

Two PoC tests were executed and both passed, mechanically confirming the finding:

1. `test_H1_deposit_claim_reverts_wrong_selector` — Proves that after a deposit is fully fulfilled, calling `redeem()` (which invokes `claimDeposit`) reverts due to the selector mismatch. The user's 100 ether remains locked in the vault with no recovery.

2. `test_CH3_no_exit_path_combined` — Proves the chain scenario: after fulfillment, `redeem()` reverts AND `cancel()` succeeds mechanically but recovers 0 assets (pending = 0 after fulfillment). The user's 100 ether remains permanently locked.

```
[PASS] test_H1_deposit_claim_reverts_wrong_selector() (gas: 328096)
  === VERIFICATION: Assets permanently locked ===
  User assets after failed redeem: 900000000000000000000
  Vault still holds user assets: 100000000000000000000

[PASS] test_CH3_no_exit_path_combined() (gas: 334166)
  === PROVEN: No exit path exists for deposit tokens ===
    - redeem() reverts (wrong function selector 0x6e553f65 vs 0x2e2d2984)
    - cancel() cannot recover claimable assets (only transfers pending=0)
```

Evidence tag: `[POC-PASS]`

**Recommendation**:

Change `claimDeposit` to use the 3-parameter `IERC7540Deposit.deposit(uint256, address, address)` call, passing the delegate address as the `controller` parameter:

```diff
  function claimDeposit(Token storage token, uint256 shares, address receiver) private returns (uint256) {
    address payable delegate = DELEGATE.predict(token.tokenId);

-   bytes memory result = Delegate(delegate).call(token.vault, abi.encodeCall(IERC4626.deposit, (shares, receiver)));
+   bytes memory result = Delegate(delegate).call(token.vault, abi.encodeCall(IERC7540Deposit.deposit, (shares, receiver, delegate)));

    return abi.decode(result, (uint256));
  }
```

---

## Medium Findings

### [M-01] requestRedeem Missing Share Approval — Complete DoS on All Redeem Requests [VERIFIED]

**Severity**: Medium
**Location**: `src/ERC7540Fungibility.sol:L304-339`
**Confidence**: HIGH (2 agents confirmed, PoC: PASS)

**Description**:
`requestRedeem()` transfers vault shares from the owner to a freshly deployed delegate contract, then calls `vault.requestRedeem(shares, delegate, delegate)` through that delegate. ERC-7540-compliant vaults implement `requestRedeem` by pulling shares from the specified owner via `transferFrom`. Because the delegate is listed as the owner, the vault calls `transferFrom(delegate, vault, shares)` — but the delegate never approved the vault to spend its shares. This `transferFrom` reverts unconditionally.

The bug is most clearly visible by comparing `requestRedeem` with its deposit counterpart. `requestDeposit` (L281) explicitly calls `Delegate(delegate).safeApprove(asset, vault, assets)` before invoking the vault. `requestRedeem` has no corresponding approval step:

```solidity
// requestDeposit — correctly approves vault to pull assets from delegate
IERC20(asset).safeTransferFrom(owner, delegate, assets);
Delegate(delegate).safeApprove(asset, vault, assets);   // L281 — approval present
bytes memory result = Delegate(delegate).call(
    vault,
    abi.encodeCall(IERC7540Deposit.requestDeposit, (assets, delegate, delegate))
);

// requestRedeem — missing equivalent approval
IERC20(vault).safeTransferFrom(owner, delegate, shares);
// no safeApprove here
bytes memory result = Delegate(delegate).call(
    vault,
    abi.encodeCall(IERC7540Redeem.requestRedeem, (shares, delegate, delegate))  // L320
);
```

The vault's `requestRedeem` calls `shareToken.transferFrom(delegate, vault, shares)`. Since no approval was granted by the delegate, this reverts. The `transferRedeem()` function, which wraps an already-existing vault request, is unaffected because it does not call `vault.requestRedeem`.

**Impact**:
`requestRedeem()` is unconditionally broken for any ERC-7540-compliant vault. Users holding vault shares cannot initiate new redeem requests through the fungibility wrapper. The redeem entry point is completely non-functional, preventing users from beginning the withdrawal flow for any vault position.

**PoC Result**:
```
[PASS] test_H2_requestRedeem_reverts_no_approval() (gas: 122741)
  CONFIRMED: requestRedeem reverts due to missing safeApprove

[PASS] test_H2_requestDeposit_works_for_comparison() (gas: 336463)
  requestDeposit succeeded, tokenId: 1
```
`requestRedeem` reverts while `requestDeposit` succeeds under identical conditions, isolating the missing approval as the sole cause.

**Recommendation**:
Add a `safeApprove` call for the vault to spend shares from the delegate before calling `vault.requestRedeem`, mirroring the pattern at L281:

```diff
  address payable delegate = DELEGATE.deploy(tokenId);

  IERC20(vault).safeTransferFrom(owner, delegate, shares);

+ Delegate(delegate).safeApprove(address(vault), vault, shares);

  bytes memory result = Delegate(delegate).call(
      vault,
      abi.encodeCall(IERC7540Redeem.requestRedeem, (shares, delegate, delegate))
  );
```

---

### [M-02] TOCTOU in transferDeposit/transferRedeem — Malicious Vault Inflates ERC-6909 Supply [VERIFIED]

**Severity**: Medium
**Location**: `src/ERC7540Fungibility.sol:L194-258`
**Confidence**: HIGH (2 agents confirmed, PoC: PASS)

**Description**:
`transferDeposit()` and `transferRedeem()` wrap existing vault requests into ERC-6909 fungible tokens. To determine how many ERC-6909 tokens to mint, the function queries the vault for the pending request size *before* transferring the request to the delegate:

```solidity
// L203: amount queried BEFORE the transfer
uint256 assets = IERC7540Deposit(vault).pendingDepositRequest(requestId, controller);
require(assets > 0, ERC7540FungibilityInvalidInput());

tokenId = ++_tokenId;
// token struct written; totalSupply[tokenId] = assets (L215); balanceOf set (L217)

address payable delegate = DELEGATE.deploy(tokenId);

// L223: request transferred AFTER the query
IERC8161DepositTransferable(vault).transferDepositRequest(requestId, controller, delegate);
```

This ordering creates a time-of-check/time-of-use (TOCTOU) gap: a malicious vault can return an inflated value from `pendingDepositRequest` before the transfer, but actually transfer only a fraction of that amount when `transferDepositRequest` is called. The contract sets `totalSupply[tokenId]` and `balanceOf` to the inflated pre-transfer query, while the real backing in the delegate corresponds only to what was genuinely transferred.

The result is ERC-6909 tokens whose stated supply exceeds the real vault position. If these tokens circulate in secondary markets, buyers pay for a claim they cannot fully exercise.

**Impact**:
A user who deploys a malicious vault can mint ERC-6909 tokens with supply arbitrarily larger than the real backing. Secondary market buyers who purchase these tokens at face value sustain a loss when they attempt to redeem and receive proportionally less than expected. The PoC demonstrates 10x inflation (reporting 1000e18, transferring 100e18).

**PoC Result**:
```
[PASS] test_H3_TOCTOU_inflated_totalSupply() (gas: 398629)
  Inflated amount reported: 1000000000000000000000
  Actual amount transferred: 100000000000000000000
  totalSupply set to: 1000000000000000000000
  CONFIRMED: totalSupply inflated by 10x via malicious vault TOCTOU
```

**Recommendation**:
Query `pendingDepositRequest` (or `pendingRedeemRequest`) *after* the transfer, using the delegate as the controller, so the measured amount reflects what was actually received:

```diff
- uint256 assets = IERC7540Deposit(vault).pendingDepositRequest(requestId, controller);
- require(assets > 0, ERC7540FungibilityInvalidInput());
-
- tokenId = ++_tokenId;
  // ...
  address payable delegate = DELEGATE.deploy(tokenId);
  IERC8161DepositTransferable(vault).transferDepositRequest(requestId, controller, delegate);

+ uint256 assets = IERC7540Deposit(vault).pendingDepositRequest(requestId, delegate);
+ require(assets > 0, ERC7540FungibilityInvalidInput());
```

Apply the equivalent change to `transferRedeem` (query `pendingRedeemRequest` after `transferRedeemRequest`, using the delegate as controller).

---

### [M-03] Operator Drains Owner Tokens via Malicious Vault [VERIFIED]

**Severity**: Medium
**Location**: `src/ERC7540Fungibility.sol:L264-302`
**Confidence**: HIGH (1 specialized agent, PoC: PASS)

*Severity adjusted from High — attack requires the owner's operator to supply a malicious vault, placing it within the ownerOrOperator trust boundary. However, operators are marked as semi-trusted, and token draining exceeds the expected operator scope.*

**Description**:
`requestDeposit()` is callable by any address that a token owner has designated as an operator. The function accepts a caller-supplied `vault` address and determines which asset to pull from the owner by calling `IERC4626(vault).asset()`. The only vault validation is an ERC-165 interface check:

```solidity
function requestDeposit(
    address vault,
    uint256 assets,
    address owner,
    address receiver
) external ownerOrOperator(owner) returns (uint256 tokenId) {
    requireInterface(vault, type(IERC7540Deposit).interfaceId);  // ERC-165 only
    // ...
    address asset = IERC4626(vault).asset();        // L275 — vault chooses the token

    address payable delegate = DELEGATE.deploy(tokenId);

    IERC20(asset).safeTransferFrom(owner, delegate, assets);  // L279 — pulls owner's tokens
```

A malicious operator deploys a vault contract that:
1. Returns the required interface IDs from `supportsInterface` to pass `requireInterface`.
2. Returns the address of a token the owner has approved to the fungibility contract from `asset()`.
3. Accepts the `requestDeposit` call without reverting.

The operator calls `requestDeposit(maliciousVault, drainAmount, owner, operator)`. The contract pulls `drainAmount` of the owner's approved tokens and sends them to the delegate — controlled by the malicious vault. The operator receives ERC-6909 tokens (as `receiver`) while the owner's funds are trapped with no legitimate redemption path.

**Impact**:
An owner who has granted operator status to a malicious account and has tokens approved to the fungibility contract can have those tokens drained in a single transaction. The PoC demonstrates draining 500e18 tokens. The ERC-165 interface check confirms interface support but provides no assurance that the vault's behaviour is honest.

**PoC Result**:
```
[PASS] test_H4_operator_drains_via_malicious_vault() (gas: 426919)
  Owner balance before: 1000000000000000000000
  Owner balance after: 500000000000000000000
  Tokens drained: 500000000000000000000
  CONFIRMED: Operator drained 500000000000000000000 tokens from owner via malicious vault
```

**Recommendation**:
1. **Vault allowlist/registry**: Restrict `requestDeposit` and `requestRedeem` to vaults registered in a trusted registry. This eliminates the malicious vault vector entirely.
2. **Balance accounting**: Measure the delegate's actual token balance before and after `safeTransferFrom` and use the delta as the authoritative deposit amount.
3. **Operator documentation**: Add a NatSpec warning to `setOperator` clearly stating that operators can specify arbitrary vaults, so users understand the trust boundary before granting operator status.

---

### [M-04] Sequential Partial Claims Subject to Exchange Rate Variation [VERIFIED]

**Severity**: Medium
**Location**: `src/ERC7540Fungibility.sol:L389-433`
**Confidence**: HIGH (3 agents confirmed, PoC: PASS)

**Description**:
When a deposit-type ERC-6909 token is redeemed via `redeem()`, the function internally calls `claimDeposit()`, which calls `vault.deposit(shares, receiver)` where `shares` is the number of ERC-6909 tokens being burned:

```solidity
function claimDeposit(Token storage token, uint256 shares, address receiver) private returns (uint256) {
    address payable delegate = DELEGATE.predict(token.tokenId);
    bytes memory result = Delegate(delegate).call(
        token.vault,
        abi.encodeCall(IERC4626.deposit, (shares, receiver))  // L419 — ERC-6909 shares passed as vault assets
    );
    return abi.decode(result, (uint256));
}
```

The ERC-4626 `deposit(assets, receiver)` function converts `assets` into vault shares at the *current* exchange rate. Because the ERC-6909 `shares` amount is passed directly as `assets`, each holder's claim is converted at the rate prevailing at the moment of their individual transaction. If multiple holders of the same tokenId claim sequentially and the vault's exchange rate changes between those transactions, early and late claimants receive different numbers of vault shares for identical ERC-6909 inputs — breaking the fundamental fungibility guarantee.

**Impact**:
Holders who claim after a rate decline receive proportionally fewer vault shares per ERC-6909 unit than earlier claimants. ERC-6909 tokens of the same tokenId are not economically equivalent, undermining the protocol's fungibility promise. This finding is related to L-21 (Tranche-settled vault — late claimants get 0), which describes the extreme end of this rate variation spectrum.

**PoC Result**:
```
[PASS] test_H6_exchange_rate_unfairness() (gas: 1343463)
  H-6: Alice burned 500 ERC-6909, rate=2.0, got vault shares: 1000000000000000000000
  H-6: Bob burned 500 ERC-6909, rate=0.5, got vault shares: 250000000000000000000
```
Alice and Bob each burned 500 ERC-6909 tokens of the same tokenId. Alice received 1000 vault shares; Bob received 250 — a 4:1 disparity for identical inputs.

**Recommendation**:
Replace `vault.deposit(shares, receiver)` with `vault.mint(shares, receiver)` in `claimDeposit`. The ERC-4626 `mint(shares, receiver)` function accepts an exact vault-share count and mints precisely that many shares to the receiver, independent of the current exchange rate. This guarantees each ERC-6909 holder redeems for the same number of vault shares:

```diff
  function claimDeposit(Token storage token, uint256 shares, address receiver) private returns (uint256) {
      address payable delegate = DELEGATE.predict(token.tokenId);
-     bytes memory result = Delegate(delegate).call(token.vault, abi.encodeCall(IERC4626.deposit, (shares, receiver)));
+     bytes memory result = Delegate(delegate).call(token.vault, abi.encodeCall(IERC4626.mint, (shares, receiver)));
      return abi.decode(result, (uint256));
  }
```

---

### [M-05] receiver=address(0) Permanently Locks Deposited Tokens and Assets [VERIFIED]

**Severity**: Medium
**Location**: `src/ERC7540Fungibility.sol:L264-339`
**Confidence**: HIGH (depth agent + 2 breadth agents, PoC: PASS)

**Description**:
The four token-creation functions — `requestDeposit`, `requestRedeem`, `transferDeposit`, and `transferRedeem` — accept a `receiver` parameter that becomes `token.owner` and the minting target for ERC-6909 balances. None of these functions validate that `receiver != address(0)`.

When `requestDeposit` is called with `receiver = address(0)`:

```solidity
IERC20(asset).safeTransferFrom(owner, delegate, assets); // L279 — assets irreversibly transferred

token.owner = receiver;                           // L290 — token.owner = address(0)
// ...
balanceOf[token.owner][tokenId] = assets;         // L297 — full supply to address(0)
```

Once minted to `address(0)`, the tokens are permanently locked with no recovery path:

- **`cancel()`** requires `msg.sender == tokens[tokenId].owner` (via `tokenOwnerOrOperator`). No externally owned account can be `address(0)`.
- **`redeem()`** requires `msg.sender == owner || isOperator[owner][msg.sender]` (via `ownerOrOperator`). Calling with `owner = address(0)` fails because no one transacts as `address(0)`.
- **`transferShares()`** has a `to != address(0)` guard, preventing the ERC-6909 tokens from being moved away from `address(0)`.

All deposited assets remain locked in the vault's delegate controller with no claim path.

**Impact**:
Any tokens deposited via `requestDeposit` or `requestRedeem` with `receiver = address(0)` are permanently irrecoverable. The same holds for `transferDeposit` and `transferRedeem`. This can occur through user error (uninitialized address variable) or through deliberate action by a malicious operator calling `requestDeposit(vault, amount, owner, address(0))` to permanently lock the owner's funds.

**PoC Result**:
```
[PASS] test_H7_zero_receiver_locks_assets() (gas: 1185842)
  H-7 CONFIRMED: 1000 ether permanently locked by receiver=address(0)
    token.owner = address(0)
    balanceOf[address(0)][tokenId] = 1000 ether
    cancel() by alice: REVERTED (ERC7540FungibilityUnauthorized)
    redeem() with owner=address(0): REVERTED (ERC7540FungibilityUnauthorized)
    Assets recoverable: 0
```

**Recommendation**:
Add zero-address validation on the `receiver` parameter at the start of all four creation functions:

```diff
  function requestDeposit(
      address vault,
      uint256 assets,
      address owner,
      address receiver
  ) external ownerOrOperator(owner) returns (uint256 tokenId) {
+     require(receiver != address(0), ERC6909InvalidReceiver(address(0)));
      requireInterface(vault, type(IERC7540Deposit).interfaceId);
```

Apply the same guard to `requestRedeem`, `transferDeposit`, and `transferRedeem`.

---

### [M-06] Cancelling a Partially-Fulfilled Request Permanently Orphans Claimable Assets [VERIFIED]

**Severity**: Medium
**Location**: `src/ERC7540Fungibility.sol:L342-371`
**Confidence**: MEDIUM (multiple agents, PoC: PASS)

**Description**:
ERC-7540 vaults may partially fulfil a deposit request: some portion of the deposited assets moves from "pending" to "claimable" while the rest remains pending. The `cancel()` function does not account for this split.

`cancel()` burns the entire ERC-6909 supply for a tokenId, then calls `transferDepositRequest` (ERC-8161) to transfer the request back to the controller:

```solidity
function cancel(uint256 tokenId, address controller) external tokenExists(tokenId) tokenOwnerOrOperator(tokenId) {
    Token storage token = tokens[tokenId];

    uint256 balance = balanceOf[token.owner][tokenId];
    require(balance == totalSupply[tokenId], ERC7540FungibilityCancelNotAllowed(tokenId));

    balanceOf[token.owner][tokenId] = 0;  // L349 — entire supply burned
    totalSupply[tokenId] = 0;             // L350

    // ...

    Delegate(delegate).call(
        token.vault,
        abi.encodeCall(
            IERC8161DepositTransferable.transferDepositRequest,
            (token.requestId, delegate, controller)  // L360
        )
    );
}
```

The ERC-8161 `transferDepositRequest` specification transfers the *pending* portion of a request — the claimable portion is settled and is not part of the pending request state. After the call, claimable assets remain assigned to the delegate in the vault, but the ERC-6909 accounting link has been destroyed (`totalSupply[tokenId] = 0`). Subsequent calls to `redeem()` will revert because there is no supply to burn. The delegate is a deterministic create2 contract with no independent withdrawal capability.

This finding is related to H-01 (claimDeposit uses wrong function selector — permanent deposit fund lock): combined, deposit-type tokens with partial fulfillment and the broken claim selector have no safe exit path under any flow.

**Impact**:
Any user who calls `cancel()` on a partially-fulfilled deposit or redeem request permanently loses the claimable portion. In the PoC: 400 ether of a 1000 ether deposit was claimable at cancel time; after `cancel()`, the 600 ether pending portion was returned to the controller, while the 400 ether claimable portion was permanently orphaned in the delegate. Partial fulfillment is a valid ERC-7540 operational mode, not malicious vault behaviour — this vulnerability affects all vaults that process requests in tranches.

**PoC Result**:
```
[PASS] test_H8_cancel_locks_claimable_portion() (gas: 1225959)
  H-8 CONFIRMED: cancel() orphans 400 ether of claimable assets
    Claimable portion stuck in delegate: 0x8d90Bd395B20511af6f35521b270B563897F2cf9
    ERC-6909 totalSupply burned to 0 -- no redemption path exists
```
After partial fulfillment (400 ether claimable, 600 ether pending) and `cancel()`:
- 600 ether pending: returned to controller
- 400 ether claimable: permanently locked in delegate

**Recommendation**:
Before allowing cancellation, verify that no claimable amount exists. If claimable > 0, require the user to claim first:

```diff
  function cancel(uint256 tokenId, address controller) external tokenExists(tokenId) tokenOwnerOrOperator(tokenId) {
      Token storage token = tokens[tokenId];

      uint256 balance = balanceOf[token.owner][tokenId];
      require(balance == totalSupply[tokenId], ERC7540FungibilityCancelNotAllowed(tokenId));

+     if (token.kind == Kind.Deposit) {
+         uint256 claimable = IERC7540Deposit(token.vault).claimableDepositRequest(
+             token.requestId, DELEGATE.predict(tokenId)
+         );
+         require(claimable == 0, "ERC7540Fungibility: claim before cancel on partial fulfillment");
+     } else {
+         uint256 claimable = IERC7540Redeem(token.vault).claimableRedeemRequest(
+             token.requestId, DELEGATE.predict(tokenId)
+         );
+         require(claimable == 0, "ERC7540Fungibility: claim before cancel on partial fulfillment");
+     }
```

Consider also providing a `claimThenCancel` convenience function that atomically claims the claimable portion before cancelling the pending remainder.

---

### [M-07] Malicious Vault Returns pending=true Permanently — redeem() Blocked Forever [VERIFIED]

**Severity**: Medium
**Location**: `src/ERC7540Fungibility.sol:L373-410`
**Confidence**: MEDIUM (1 agent confirmed, PoC: PASS)

**Description**:
`redeem()` unconditionally calls `pending(tokenId)` and reverts if it returns `true`:

```solidity
function redeem(
    uint256 tokenId,
    uint256 shares,
    address receiver,
    address owner
) external ownerOrOperator(owner) tokenExists(tokenId) returns (uint256 assets) {
    require(pending(tokenId) == false, ERC7540FungibilityPending(tokenId));  // L395
    // ...
}

function pending(uint256 tokenId) public view returns (bool) {
    Token storage token = tokens[tokenId];
    return token.kind == Kind.Deposit ? pendingDeposit(token) : pendingRedeem(token);
}

function pendingDeposit(Token storage token) private view returns (bool) {
    address delegate = DELEGATE.predict(token.tokenId);
    return IERC7540Deposit(token.vault).pendingDepositRequest(token.requestId, delegate) > 0;  // L380
}
```

The `pending()` check delegates entirely to the vault's `pendingDepositRequest` (or `pendingRedeemRequest`) return value. There is no time-based override, admin override, or cross-check against `claimableDepositRequest` as a fallback readiness signal. There is no alternative claim path that bypasses the `pending()` check.

A malicious vault that always returns a non-zero value from `pendingDepositRequest` causes `pending()` to permanently return `true` and `redeem()` to permanently revert with `ERC7540FungibilityPending`. The `requireInterface` guard at token creation validates only the ERC-165 interface ID — not that `pendingDepositRequest` returns honest values. A vault can be both interface-compliant and behaviourally malicious.

Note: `cancel()` does not check `pending()`, so single-holder positions may still be cancellable — but when combined with M-06 (partial fulfillment), cancel also leads to fund loss.

**Impact**:
Any user who interacts with a vault that permanently signals pending (whether deliberately malicious or buggy) loses access to their funds via `redeem()`. The vault address is user-supplied with no allowlist — anyone can deploy a conforming but dishonest vault. The PoC demonstrates 500 ether being permanently inaccessible via `redeem()`, with the condition persisting after 365 days and 1 million blocks.

**PoC Result**:
```
[PASS] test_H21_always_pending_vault_blocks_redeem() (gas: 1139234)
  H-21 CONFIRMED: redeem() permanently blocked by always-pending vault
    pending() after fulfillDeposit: true (always)
    redeem() immediately: REVERTED (ERC7540FungibilityPending)
    redeem() after 365 days + 1M blocks: REVERTED (ERC7540FungibilityPending)
    Assets recoverable via redeem: 0 of 500 ether
```

**Recommendation**:
Add `claimableDepositRequest` / `claimableRedeemRequest` as a secondary readiness oracle in `pending()`. If the vault reports a non-zero claimable amount, the request is ready to claim regardless of the pending signal:

```diff
  function pendingDeposit(Token storage token) private view returns (bool) {
      address delegate = DELEGATE.predict(token.tokenId);
+     // If claimable > 0, the deposit is ready regardless of the pending signal
+     if (IERC7540Deposit(token.vault).claimableDepositRequest(token.requestId, delegate) > 0) {
+         return false;
+     }
      return IERC7540Deposit(token.vault).pendingDepositRequest(token.requestId, delegate) > 0;
  }
```

Apply the equivalent change to `pendingRedeem`. This makes `pending()` resistant to vaults that fail to clear their pending signal after fulfillment, while remaining fully compatible with honest vault implementations.

---

## Low Findings

### [L-01] Cancelled Token Struct Persists — Stale State After Cancel [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L342-371`
**Confidence**: HIGH (multiple agents confirmed, CODE-TRACE verified)

**Description**:
When `cancel()` executes, it correctly zeroes both `balanceOf[token.owner][tokenId]` and `totalSupply[tokenId]` (L349-350), but it never deletes the `tokens[tokenId]` mapping entry. The `Token` struct — containing the vault address, request ID, kind, and owner — remains in storage with its original values after cancellation. Because the `tokenExists` modifier checks only that `tokens[tokenId].tokenId > 0` (L65), any subsequent call that uses `tokenExists` will treat the cancelled token as still existing. This stale struct is the root cause enabling two downstream issues: double-cancel (see L-15) and the ambiguous return value from `pending()` on cancelled tokens (see I-04).

**Impact**:
- Downstream functions relying on `tokenExists` as a liveness check will pass for cancelled tokens.
- Stale struct enables the double-cancel reachability path described in L-15.
- `pending()` called on a cancelled tokenId returns a vault-queried result, creating misleading off-chain signals.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Add `delete tokens[tokenId];` at the end of the `cancel()` function body after the delegate call block. This sets the struct to zero and causes `tokenExists` to return false for the cancelled ID, preventing all downstream stale-state paths.

---

### [L-02] token.owner Immutable After Mint — Cancel Blocked for Transferees [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L342-371`
**Confidence**: HIGH (depth agents confirmed)

**Description**:
The `token.owner` field in the `Token` struct is written once at mint time and never updated thereafter. `transferShares` (L133-146) adjusts only `balanceOf[from][id]` and `balanceOf[to][id]` — the struct field is untouched. The `cancel()` function at L346 reads `balanceOf[token.owner][tokenId]` to verify the original owner still holds the full supply. After any ERC-6909 transfer from Alice (the original owner) to Bob, `token.owner` still equals Alice but `balanceOf[Alice][id]` is now 0. The guard at L347 then checks `0 == totalSupply`, which fails — permanently blocking cancellation for all parties.

**Impact**:
- After any ERC-6909 transfer, cancel is permanently unavailable for all parties including a new holder who owns 100% of the supply.
- Users who receive tokens via secondary-market purchase and expect cancel capability are denied that path with no on-chain warning.
- Combined with H-01 (broken claimDeposit), a secondary buyer of deposit-type tokens may have no exit path at all.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Consider updating `token.owner` within `transferShares` when the stored `token.owner` address transfers its entire balance (i.e., when `balanceOf[from][id]` drops to zero post-transfer and `from == token.owner`). At minimum, add explicit NatSpec warnings on `transfer` and `transferFrom` documenting that cancel becomes unavailable after any transfer.

---

### [L-03] No Slippage Protection on Redeem Claim [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L389-410`
**Confidence**: UNCERTAIN (0.67, CODE-TRACE only)

**Description**:
The `redeem()` function (L389-410) calls `claim(token, shares, receiver)` → `claimRedeem` (L424-432) → `IERC4626.redeem(shares, receiver, delegate)`, returning however many underlying assets the vault distributes for the given share amount at the current exchange rate. There is no `minAssets` parameter accepted by `redeem()`, no minimum-out check anywhere in the call chain, and no slippage protection of any kind. The caller accepts whatever the vault returns unconditionally. Because ERC-6909 shares are burned before the vault call (L402-403), the caller cannot abort after observing the payout — the burn is irreversible regardless of the amount received.

**Impact**:
- Callers cannot enforce a minimum acceptable payout for their redeemed shares.
- In volatile vault conditions or when transactions are sandwiched by MEV, the effective exchange rate at execution may differ significantly from the rate at submission.
- Asset loss from unfavorable exchange rate movement is irreversible once shares are burned.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Add a `minAssets` parameter to `redeem()` and enforce `require(assets >= minAssets)` after the claim call returns. Alternatively, provide a view function that quotes the expected payout at the current exchange rate so callers can determine slippage tolerance off-chain.

---

### [L-04] decimals() Returns Swapped Values for Deposit vs Redeem Tokens [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L177-187`
**Confidence**: UNCERTAIN (0.58, CODE-TRACE only)

**Description**:
The `decimals(uint256 id)` function at L184-186 contains an inverted ternary condition:

```solidity
dec = tokens[id].kind == Kind.Deposit
  ? IERC20Metadata(vault).decimals()                        // vault share decimals
  : IERC20Metadata(IERC4626(vault).asset()).decimals();     // underlying asset decimals
```

A Deposit-type ERC-6909 token represents a pending asset deposit — its balance is denominated in units of the underlying asset (e.g., USDC), so it should return asset decimals. A Redeem-type token represents pending vault shares, so it should return vault share decimals. The current code does the opposite. For a USDC vault (6-decimal assets, 18-decimal shares), Deposit tokens incorrectly report 18 decimals, causing off-chain tooling to misscale balances by up to 10^12.

**Impact**:
- Any wallet, indexer, or secondary market that normalizes ERC-6909 balances using `decimals()` will display incorrect values for both token kinds.
- Deposit tokens backed by 6-decimal USDC displayed as 18-decimal appear 10^12 times smaller than their actual USDC value.
- Composed with the TOCTOU supply inflation (M-02), this mismatch enables secondary market price deception (see L-17).

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Swap the ternary branches:
```solidity
dec = tokens[id].kind == Kind.Deposit
  ? IERC20Metadata(IERC4626(vault).asset()).decimals()  // asset decimals for Deposit tokens
  : IERC20Metadata(vault).decimals();                   // vault share decimals for Redeem tokens
```

---

### [L-05] supportsInterface Does Not Register IERC7540Fungibility [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L74-80`
**Confidence**: UNCERTAIN (0.68, CODE-TRACE only)

**Description**:
The `supportsInterface()` implementation at L74-80 registers `IERC6909`, `IERC6909Metadata`, `IERC6909TokenSupply`, and the ERC165 base. `type(IERC7540Fungibility).interfaceId` is never included. The contract implements the `IERC7540Fungibility` interface (declared at L21), but any external consumer calling `supportsInterface(type(IERC7540Fungibility).interfaceId)` receives `false`. For composability-focused infrastructure where third parties are expected to programmatically discover capabilities, missing ERC-165 registration is a meaningful integration gap.

**Impact**:
- ERC-165 capability discovery for `IERC7540Fungibility` returns `false`, causing composing contracts or routers that use interface detection to skip the contract or revert.
- Integration tools and explorers relying on ERC-165 for interface classification will not identify this contract as implementing ERC-7540 fungibility semantics.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Add `type(IERC7540Fungibility).interfaceId` to the `supportsInterface` return expression:
```solidity
return
  super.supportsInterface(interfaceId) ||
  interfaceId == type(IERC6909).interfaceId ||
  interfaceId == type(IERC6909Metadata).interfaceId ||
  interfaceId == type(IERC6909TokenSupply).interfaceId ||
  interfaceId == type(IERC7540Fungibility).interfaceId;
```

---

### [L-06] cancel() Missing Zero-Address Validation on controller [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L342-371`
**Confidence**: UNCERTAIN (0.64, CODE-TRACE only)

**Description**:
The `cancel()` function accepts a `controller` parameter (L342) and passes it directly to `transferDepositRequest` or `transferRedeemRequest` at L360-367 with no `require(controller != address(0))` guard. If the caller passes `address(0)`, the vault request is transferred to the zero address. No account can ever control address(0), so the vault position becomes permanently inaccessible. The ERC-6909 supply is already burned at L349-350 before the vault call, eliminating any rollback possibility.

**Impact**:
- A caller or operator who passes `controller=address(0)` to `cancel()` permanently surrenders the vault's pending position (all assets or shares) to an uncontrollable address.
- ERC-6909 supply is simultaneously and irrevocably burned.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Add a zero-address check at the start of `cancel()`:
```solidity
require(controller != address(0), ERC7540FungibilityInvalidInput());
```

---

### [L-07] Residual Delegate Approval After requestDeposit [CONTESTED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L281`
**Confidence**: UNCERTAIN (0.55, CODE-TRACE only)

**Description**:
In `requestDeposit`, line L281 executes `Delegate(delegate).safeApprove(asset, vault, assets)`, granting the vault an ERC-20 allowance of exactly `assets` over the delegate's token balance. For standard ERC-7540 vaults that immediately pull funds during `requestDeposit`, the vault consumes the full allowance via `transferFrom` and the residual approval is zero. However, for non-standard vaults that record intent without immediately pulling (or pull a different amount), a non-zero residual approval persists on the delegate indefinitely. The risk materializes only for non-conformant vaults where the delegate retains a positive token balance alongside an active approval.

**Impact**:
- For non-standard vaults that do not immediately pull on `requestDeposit`, the delegate retains both an asset balance and an active vault approval — a potential fund exposure if the vault later exercises the residual approval maliciously.
- Standard ERC-7540 conformant vaults are not affected.

**PoC Result**: [CODE-TRACE] — verdict CONTESTED; exploitability depends on vault behavior.

**Recommendation**:
After the `Delegate(delegate).call(vault, ...)` at L283-286, revoke the delegate's approval: `Delegate(delegate).safeApprove(asset, vault, 0)`. This ensures zero residual allowance regardless of vault pull behavior.

---

### [L-08] requestId Uniqueness Not Validated [CONTESTED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L293-330`
**Confidence**: UNCERTAIN (0.55, CODE-TRACE only)

**Description**:
The `requestId` returned by the vault's `requestDeposit` call (L293) and the caller-supplied `requestId` in `transferDeposit` (L203) are stored without any uniqueness check against existing tokens. Two distinct ERC-6909 tokens could reference the same `vault + requestId` combination. When the first token exercises ERC-8161 `transferDepositRequest` for a given `requestId`, vault request ownership moves to that token's delegate; the second token's subsequent attempt to transfer the same `requestId` from the original controller will likely fail at the vault, rendering the second token's ERC-6909 supply permanently unbacked.

**Impact**:
- Two tokens sharing the same `vault + requestId` results in at most one being usable; the second token's ERC-6909 shares become permanently unbacked.
- Holders of the second token cannot cancel or redeem against the vault position.

**PoC Result**: [CODE-TRACE] — verdict CONTESTED; exploitability depends on vault behavior.

**Recommendation**:
Maintain a mapping `usedRequestIds[vault][requestId] = tokenId` and require that a new requestId is not already registered for the given vault before minting. Alternatively, document this as a vault-behavior assumption.

---

### [L-09] Operator Can Redirect Redeemed Assets to Arbitrary Receiver [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L389-410`
**Confidence**: UNCERTAIN (0.61, CODE-TRACE only)

*Severity adjusted — attack requires an operator acting beyond intended "act on behalf of" semantics; operator is a semi-trusted actor per trust assumption #8.*

**Description**:
The `redeem()` function at L389 is protected by `ownerOrOperator(owner)`. The `receiver` parameter is passed without restriction to `claimRedeem` → `vault.redeem(shares, receiver, delegate)` at L429. An approved operator (Bob) can call `redeem(tokenId, shares, receiver=Bob, owner=Alice)`: the `ownerOrOperator(Alice)` check passes because Bob is Alice's operator, Alice's ERC-6909 balance is burned at L402, and the vault sends the underlying assets to Bob rather than Alice. There is no requirement that `receiver` equal `owner` or any pre-authorized address.

**Impact**:
- An operator can extract the full economic value of the owner's ERC-6909 position to themselves.
- The owner loses the redeemed assets; shares are burned before the vault call, leaving no recovery path.
- This requires the owner to have explicitly granted operator status.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Consider restricting `receiver` in operator-initiated `redeem()` calls to be either the `owner` or an address the `owner` has explicitly authorized. Alternatively, document this capability clearly in the operator trust model so users understand the implications before granting operator status.

---

### [L-10] Asset Depositor Loses Authority When receiver != owner [CONTESTED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L264-302`
**Confidence**: UNCERTAIN (0.55, CODE-TRACE only)

**Description**:
In `requestDeposit(vault, assets, owner, receiver)`, the `owner` parameter is the source of funds (assets are pulled from `owner` at L279), while `receiver` receives the minted ERC-6909 tokens and is stored as `token.owner` (L290). When `receiver != owner`, the original asset depositor (Alice) permanently and irrevocably loses all authority over the position: `cancel()` checks `tokenOwnerOrOperator(tokenId)` against `tokens[tokenId].owner` (= Bob), and `redeem()` requires `ownerOrOperator(owner_param)` where the caller must prove authority over the ERC-6909 balance holder. Alice has no recovery path unless Bob grants her operator status.

**Impact**:
- The original asset depositor cannot cancel or redeem the position they funded if they specified a different receiver.
- The authority loss is permanent and irreversible without the receiver's cooperation.

**PoC Result**: [CODE-TRACE] — verdict CONTESTED; potentially by design given the `receiver` parameter semantics.

**Recommendation**:
Add explicit NatSpec documentation to `requestDeposit` and `requestRedeem` warning that passing `receiver != owner` permanently transfers all authority over the position to the receiver. Consider whether an authority delegation pattern (granting the original `owner` operator status automatically when `receiver != owner`) would better match user expectations.

---

### [L-11] Full ERC-6909 Transfer Permanently Prevents Cancel for All Parties [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L342-371`
**Confidence**: HIGH (confirmed)

**Description**:
As a consequence of `token.owner` being immutable after mint (see L-02), any ERC-6909 transfer of a tokenId — including a full transfer of the total supply from the original owner to a new holder — permanently blocks `cancel()` for all parties. After Alice transfers all shares to Bob: `token.owner = Alice`, `balanceOf[Alice][id] = 0`, `balanceOf[Bob][id] = totalSupply`. When `cancel()` is called, L346 reads `balance = balanceOf[token.owner][id] = balanceOf[Alice][id] = 0` and L347 checks `require(0 == totalSupply)` — which fails because totalSupply is still the original amount. Bob holds the entire supply but cannot cancel; Alice no longer holds any shares but remains the stored `token.owner`.

**Impact**:
- Secondary market buyers who acquire 100% of a tokenId's supply cannot cancel the underlying vault position.
- Combined with H-01 (broken claimDeposit), a full secondary-market buyer of deposit-type tokens has no exit path.
- The `redeem()` path remains available once the vault fulfills, but cancel is permanently removed as an option.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
If the design intent is that transfer permanently blocks cancel, add NatSpec documentation to `transfer` and `transferFrom` making this explicit. If full-balance transferees should be able to cancel, update `token.owner` when the full balance is transferred out.

---

### [L-12] Returndata Bomb from Malicious Vault via Delegate Call [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L223-258`
**Confidence**: UNCERTAIN (0.55, CODE-TRACE only)

**Description**:
The `Delegate(delegate).call(vault, ...)` pattern used in `claimDeposit` (L419), `claimRedeem` (L427-430), and the `cancel()` delegate calls (L358-368) does not cap the size of returndata before calling `abi.decode(result, (uint256))`. A malicious vault can return arbitrarily large returndata: `abi.decode` allocates memory proportional to the returndata length, and Solidity memory expansion costs scale quadratically with total memory used. A vault returning several megabytes of returndata can cause the caller's transaction to run out of gas before the decode completes. Since all exit paths (`redeem`, `cancel`) route through the same uncapped delegate call pattern, a malicious vault can use this to permanently DoS all ERC-6909 holders.

**Impact**:
- A malicious vault can cause all `redeem()` and `cancel()` calls to revert out-of-gas, permanently locking token holders' funds.
- No recovery path exists since all exit functions route through the uncapped delegate call pattern.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Check returndata size before decoding. After each `Delegate(delegate).call(...)`, assert `result.length == 32` (a single `uint256` return should be exactly 32 bytes) before `abi.decode`. Revert with a descriptive error if the returndata is unexpectedly large.

---

### [L-13] redeem() receiver=address(0) Sends Assets to Dead Address [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L389-410`
**Confidence**: UNCERTAIN (0.60, CODE-TRACE only)

**Description**:
The `redeem()` function at L394 accepts a `receiver` parameter with no zero-address validation. At L402-403, the caller's ERC-6909 shares are burned and `totalSupply` is reduced before the vault call. The `receiver` is then passed to `claimRedeem` → `vault.redeem(shares, receiver, delegate)` at L429. If `receiver = address(0)` and the vault does not independently reject a zero-address recipient, the underlying assets are transferred to address(0) and permanently lost. The burn at L402-403 is not reversible, so no rollback is possible after the vault sends to address(0). This is a parallel gap to M-05 (which covers `receiver=address(0)` in `requestDeposit`/`requestRedeem`); the same guard is missing from the `redeem()` claim path.

**Impact**:
- A caller who accidentally provides `receiver=address(0)` to `redeem()` permanently loses the underlying assets corresponding to the burned ERC-6909 shares.
- No recovery is possible after the vault call completes.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Add a zero-address check at the start of `redeem()`:
```solidity
require(receiver != address(0), ERC7540FungibilityInvalidInput());
```

---

### [L-14] cancel() controller=address(this) Locks Vault Request in Contract [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L342-371`
**Confidence**: UNCERTAIN (0.55, CODE-TRACE only)

**Description**:
The `cancel()` function does not check that `controller != address(this)`. If a caller passes `controller = address(this)`, the vault transfers request ownership to the ERC7540Fungibility contract itself via `transferDepositRequest(requestId, delegate, address(this))` at L360. The ERC7540Fungibility contract has no function to exercise a vault request on its own behalf — all vault interactions are routed through individual delegate clones and are request-specific. The received vault request is permanently locked in the contract with no recovery mechanism. Unlike L-06 (zero-address), the contract address is a valid non-zero address, so no existing guard catches this path. The caller's ERC-6909 shares have already been burned at L349-350 before the delegate call, eliminating any rollback.

**Impact**:
- A caller who passes `controller=address(this)` permanently surrenders the vault-side pending position to the contract itself, where it is irrecoverable.
- ERC-6909 supply is simultaneously burned.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Extend controller validation in `cancel()` to exclude both the zero address and the contract's own address:
```solidity
require(controller != address(0) && controller != address(this), ERC7540FungibilityInvalidInput());
```

---

### [L-15] Double-Cancel via Stale Token Struct [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L342-371`
**Confidence**: UNCERTAIN (0.64, CODE-TRACE only)

**Description**:
Because `cancel()` never deletes the `tokens[tokenId]` struct (see L-01), a second `cancel()` call with the same tokenId can pass all guards. After the first cancel: `balanceOf[token.owner][tokenId] = 0` and `totalSupply[tokenId] = 0`. The second cancel: `tokenExists` passes (struct still present), `tokenOwnerOrOperator` passes for the original owner, L346 reads `balance = 0`, L347 checks `require(0 == 0)` — passes. The delegate call `transferDepositRequest(requestId, delegate, controller)` is then executed with stale state — the delegate no longer controls the vault request (transferred out on first cancel). In the typical case the vault reverts on this spurious call, causing the double-cancel to revert. For non-standard vaults with permissive transfer semantics, unintended state transitions at the vault level are possible.

**Impact**:
- The vault receives a spurious transfer request for a requestId the delegate no longer controls.
- In the typical case: second cancel reverts — mild nuisance.
- For non-standard vaults: potential unintended vault-side state transitions.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Delete the token struct in `cancel()` as recommended in L-01 (`delete tokens[tokenId]`). This causes `tokenExists` to return false after cancellation, preventing all subsequent calls including double-cancel.

---

### [L-16] Partial Fulfillment totalSupply Mismatch — Last Redeemer Blocked [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L389-433`
**Confidence**: MEDIUM (confirmed)

**Description**:
For vaults that deduct fees on fulfillment, the claimable position held by the delegate will be smaller than `totalSupply[tokenId]` set at mint time. At mint, `totalSupply[tokenId]` is set to the full pending amount (e.g., 100 shares). After vault fulfillment with a 2% fee, the delegate controls only 98 claimable shares. Early redeemers burn ERC-6909 shares and receive vault assets proportionally. When the final redeemer attempts to claim their remaining shares, the vault has already distributed all of the fulfilled position — the `vault.redeem` call either reverts or returns 0 assets. The ERC-6909 shares are burned before the vault call (L402-403), so if the vault returns 0 or reverts, the last holder loses their position with no claim or recovery path.

**Impact**:
- For fee-charging vaults, the last ERC-6909 holder absorbs the full fee shortfall.
- The final `redeem()` call may leave the last holder with no shares and no redeemed assets.
- Standard fee-free vaults are not affected.

**PoC Result**: [CODE-TRACE] — confirmed via manual trace; no executed PoC.

**Recommendation**:
Use `claimableDepositRequest`/`claimableRedeemRequest` to read the vault's actual available balance before burning ERC-6909 shares, capping the redeemable amount to `min(shares, claimableForDelegate)`. This prevents burn-before-call scenarios where the vault has insufficient balance to fulfill the claim.

---

### [L-17] Composed: Malicious Vault Supply Inflation + Swapped decimals() Enables Secondary Market Price Deception [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L194-226` (transferDeposit), `L177-187` (decimals)
**Confidence**: MEDIUM

*Originally assessed as Medium; capped at Low under proven-only mode (no executed PoC).*

**Description**:
Two independently confirmed findings compose into a more severe attack against secondary market participants. `transferDeposit` sets `totalSupply[tokenId]` to the value returned by `pendingDepositRequest()` without independent verification — a malicious vault returns an inflated pending amount, minting far more ERC-6909 tokens than the actual vault-side backing (M-02 component). Additionally, `decimals()` returns vault share decimals for Deposit-type tokens instead of the correct asset decimals (L-04 component). For a USDC vault (6-decimal assets, 18-decimal shares), Deposit tokens report 18 decimals while the balance is in USDC units.

A malicious vault operator can engineer `pendingDepositRequest` to return an inflated value calibrated against the decimal mismatch: the resulting ERC-6909 position displays a normalized balance that looks correct to standard tooling (dividing by 10^18), while the actual vault backing is orders of magnitude smaller. Standard ERC-6909 pricing tools have no defense against this composition.

**Impact**:
- Secondary market participants using standard ERC-6909 pricing tools are systematically misled about the real backing value of Deposit-type positions.
- Attackers can sell inflated, mis-priced positions to secondary buyers at prices far above actual vault position value.
- Both component bugs must be fixed to eliminate the composed attack surface.

**PoC Result**: [CODE-TRACE] — confirmed via manual code trace; no executed PoC (capped to Low under proven-only mode).

**Recommendation**:
Fix both component issues independently: (1) correct the `decimals()` ternary inversion (see L-04), and (2) prevent supply inflation by verifying the vault-transferred amount against the amount reported by `pendingDepositRequest` (see M-02). Fixing either component substantially reduces the composition attack surface.

---

### [L-18] Composed: Non-ERC-8161 Vault + Partial Fulfillment — Total Deadlock [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L264-433`
**Confidence**: MEDIUM

*Originally assessed as Medium; capped at Low under proven-only mode (no executed PoC).*

**Description**:
Two independently confirmed findings compose into a complete deadlock for users. `requestDeposit` (L270) checks only `IERC7540Deposit` at creation time, not ERC-8161 — valid per ERC-7540, which does not mandate ERC-8161. If such a vault partially fulfills the deposit request, the user faces blocking conditions on both exits: `redeem()` is blocked by `pending() == false` at L395 (the unfulfilled portion keeps `pending = true`), and `cancel()` is blocked by `requireInterface(vault, IERC8161)` at L357 (vault lacks ERC-8161). The user has no available action until the vault fulfills 100% of the request. If the vault is delayed, paused, or never fully completes the request, all user assets — both the claimable fulfilled portion and the pending portion — are permanently inaccessible.

**Impact**:
- Any valid ERC-7540 vault without ERC-8161 that partially fulfills a deposit request leaves the user with no available action.
- Both fulfilled (claimable) and unfulfilled (pending) portions are inaccessible until full fulfillment.
- Permanent fund lock if the vault never achieves 100% fulfillment.

**PoC Result**: [CODE-TRACE] — confirmed via manual code trace; no executed PoC (capped to Low under proven-only mode).

**Recommendation**:
Either (1) require ERC-8161 support at `requestDeposit` time so cancel is always available, or (2) allow partial claim of the fulfilled portion while the pending portion remains in the vault by relaxing the `pending() == false` guard in `redeem()` to check for claimable balance directly rather than requiring full fulfillment.

---

### [L-19] Operator Permanently Locks Owner's Funds via receiver=address(0) [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L264-302`
**Confidence**: MEDIUM

*Originally assessed as Medium; capped at Low under proven-only mode (no executed PoC).*

**Description**:
This finding is the operator-actor variant of M-05. The `ownerOrOperator(owner)` modifier permits an approved operator to call `requestDeposit` and `requestRedeem` with any `receiver` address, including `address(0)`. When an operator calls `requestDeposit(vault, assets, victimOwner, address(0))`:

- `victimOwner`'s assets are pulled via `safeTransferFrom(owner, delegate, assets)` at L279
- `token.owner = address(0)` is stored at L290
- `balanceOf[address(0)][tokenId] = assets` is set at L297

All recovery paths permanently fail: `cancel()` requires `tokenOwnerOrOperator(tokenId)` which checks against `tokens[tokenId].owner = address(0)` — no msg.sender can equal address(0); `redeem()` requires `ownerOrOperator(address(0))` — same impossibility; `transferShares` requires `from != address(0)` (L134). The same attack applies to `requestRedeem`.

**Impact**:
- A rogue operator can permanently destroy 100% of the victim owner's deposited or redeemed assets with a single malicious transaction.
- No recovery path exists for the victim after the call completes.
- This extends operator power substantially beyond the "act on behalf of" semantics of the operator trust model.

**PoC Result**: [CODE-TRACE] — confirmed via manual code trace; no executed PoC (capped to Low under proven-only mode).

**Recommendation**:
Add `require(receiver != address(0), ERC7540FungibilityInvalidInput())` to both `requestDeposit` and `requestRedeem` (and analogously to `transferDeposit` and `transferRedeem`). This resolves both the user-error scenario (M-05) and the operator-griefing scenario simultaneously.

---

### [L-20] Vault Upgrade Removing ERC-8161 Blocks cancel() for Existing Positions [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L342-371` (cancel), `L200-201` (transferDeposit interface check)
**Confidence**: MEDIUM

*Originally assessed as Medium; capped at Low under proven-only mode (no executed PoC).*

**Description**:
`transferDeposit` and `transferRedeem` verify ERC-8161 support at creation time (L200-201, L235-236). However, `cancel()` re-checks ERC-8161 support at runtime (L357, L363) by querying the vault's current ERC-165 registry. For upgradeable vaults (UUPS, Transparent Proxy, Beacon — common in DeFi), if ERC-8161 is removed from the vault's interface registry after positions are created, all subsequent `cancel()` calls will fail for those positions. This is a TOCTOU vulnerability: the interface was verified at creation but must pass again at cancel time. Users who created positions when ERC-8161 was available find that cancellation is permanently blocked following a vault upgrade, without any on-chain signal.

**Impact**:
- All positions created via `transferDeposit`/`transferRedeem` against an upgradeable vault lose cancel capability if the vault removes ERC-8161.
- If the vault also suspends fulfillment during migration, users face a complete fund lock — neither cancel nor redeem is available.
- Users had a legitimate expectation of cancel availability that a vault upgrade silently invalidates.

**PoC Result**: [CODE-TRACE] — confirmed via manual code trace; no executed PoC (capped to Low under proven-only mode).

**Recommendation**:
Store a boolean `token.cancelable = true` at creation time for tokens where ERC-8161 was confirmed, and check this flag in `cancel()` instead of re-querying the vault's current ERC-165 state. This preserves the capability snapshot from creation time and makes the contract's behavior invariant to post-creation vault upgrades.

---

### [L-21] Tranche-Settled Vault — Late Claimants Get 0 [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L389-433`
**Confidence**: UNCERTAIN (0.50, CODE-TRACE only)

*Originally assessed as Medium; capped at Low under proven-only mode (no executed PoC).*

**Description**:
For tranche-settled vaults — where the vault processes a batch of redemptions and distributes a fixed pool of assets before closing the settlement tranche — the vault's claimable balance depletes as ERC-6909 holders call `redeem()`. Early redeemers extract assets at the current exchange rate; when combined with the exchange rate variation described in M-04, early claimants may extract a disproportionate share. The final `vault.redeem` call for the last holder may then encounter a vault that has already exhausted its claimable position. The final holder's ERC-6909 shares are burned at L402-403 before the vault call, so if the vault returns 0 assets or reverts, the last holder loses their ERC-6909 position with no claim or recovery path.

**Impact**:
- For tranche-settled vaults with exchange rate variation, late ERC-6909 holders may receive zero assets despite holding valid shares.
- The ERC-6909 shares are burned before the vault call, so a vault that reverts on zero-balance redeem leaves the last holder with no shares and no assets.
- Standard proportional settlement vaults are not affected.

**PoC Result**: [CODE-TRACE] — confirmed as PARTIAL via manual code trace; no executed PoC (capped to Low under proven-only mode).

**Recommendation**:
Check the vault's actual claimable balance using `claimableDepositRequest`/`claimableRedeemRequest` before burning ERC-6909 shares, and cap the redeemable amount to `min(shares, claimableForDelegate)`. This prevents scenarios where the vault is exhausted before all ERC-6909 shares are redeemed.

---

### [L-22] Fee-on-Transfer Tokens Cause requestDeposit DoS or Supply Inflation [VERIFIED]

**Severity**: Low
**Location**: `ERC7540Fungibility.sol:L279-301`
**Confidence**: HIGH (0.74, multiple agents, [POC-PASS])

*Downgraded from Medium: protocol trust assumption #4 explicitly excludes fee-on-transfer tokens from the supported asset class.*

**Description**:
In `requestDeposit`, assets are pulled from the owner via `safeTransferFrom(owner, delegate, assets)` at L279, and `totalSupply[tokenId]` is then set to `assets` at L295. For fee-on-transfer (FoT) tokens, the delegate receives `assets - fee` rather than `assets`. The contract then approves the vault for the full `assets` amount (L281) and calls `vault.requestDeposit(assets, delegate, delegate)` (L283-285). If the vault validates that the delegate has sufficient balance to cover the pull, the call reverts (DoS). If the vault accepts the call and pulls the full `assets` amount, the delegate has insufficient balance — the transfer fails or the vault's internal accounting is misaligned with the ERC-6909 `totalSupply` (supply inflation). Trust assumption #4 states FoT tokens are not supported, but this restriction is not enforced on-chain, making the failure mode silent.

**Impact**:
- FoT tokens cause `requestDeposit` to either DoS (recoverable, transaction reverts) or produce ERC-6909 tokens with `totalSupply` greater than actual vault-side backing (not recoverable).
- In the supply inflation case, the last redeemer receives insufficient assets since the vault position is smaller than the ERC-6909 supply records.

**PoC Result**: [POC-PASS] — mechanically verified with an executed PoC; downgrade to Low is solely due to the explicit protocol trust assumption excluding FoT tokens.

**Recommendation**:
Add an on-chain balance check after `safeTransferFrom` to compare the delegate's actual received balance against the declared `assets` amount:
```solidity
uint256 received = IERC20(asset).balanceOf(delegate);
require(received == assets, ERC7540FungibilityInvalidInput()); // reject FoT tokens explicitly
```
This transforms the silent failure into a clear and self-documenting revert, making the trust assumption self-enforcing.

---

## Informational Findings

### [I-01] Self-Approval in setOperator [VERIFIED]

**Severity**: Informational
**Location**: `ERC7540Fungibility.sol:L107-115`

**Description**:
The `setOperator` function at L107 validates only that `spender != address(0)`. There is no guard preventing `spender == msg.sender`. A caller can execute `setOperator(msg.sender, true)`, which stores `isOperator[Alice][Alice] = true` and emits `OperatorSet(Alice, Alice, true)`. The self-operator status has no functional effect — the `ownerOrOperator` modifier's first branch `msg.sender == owner` already passes for any address acting on its own behalf — but the event emission is misleading. Off-chain indexers and monitoring systems that track operator relationships will record a self-approval that does not represent any real permission grant.

**Impact**:
- Misleading `OperatorSet` events where `owner == operator` may confuse indexers, dashboards, or monitoring systems.
- No functional on-chain impact; the stored approval is redundant.

**Recommendation**:
Add `require(spender != msg.sender)` to `setOperator` to prevent self-approval and eliminate misleading event emissions.

---

### [I-02] name() and symbol() Return Empty Strings [VERIFIED]

**Severity**: Informational
**Location**: `ERC7540Fungibility.sol:L171-175`

**Description**:
The `name(uint256 id)` function at L171 and `symbol(uint256 id)` at L173 are declared with empty function bodies and no return statements. Solidity returns the zero value for `string memory` — an empty string — when no return statement is present. Both functions are part of the `IERC6909Metadata` interface that the contract claims to implement (registered in `supportsInterface` at L78). Any wallet, marketplace, indexer, or composing contract querying `name()` or `symbol()` for a token receives empty strings with no indication of the underlying vault, asset, or token kind the position represents.

**Impact**:
- Token display in wallets and explorers shows no identifying metadata, reducing user comprehension.
- Off-chain tooling that filters or routes by `name()` or `symbol()` cannot distinguish ERC7540Fungibility tokens from one another.

**Recommendation**:
Implement `name()` and `symbol()` to return meaningful identifiers derived from the underlying vault and token kind. For example:
```solidity
function name(uint256 id) external view returns (string memory) {
    Token storage token = tokens[id];
    string memory kind = token.kind == Kind.Deposit ? "Deposit" : "Redeem";
    return string.concat("ERC7540-", kind, "-", Strings.toHexString(token.vault));
}
```

---

### [I-03] Zero-Amount ERC-6909 Transfers Allowed [VERIFIED]

**Severity**: Informational
**Location**: `ERC7540Fungibility.sol:L133-146`

**Description**:
The `transferShares` private function at L133 processes ERC-6909 transfers without a `require(amount > 0)` guard. The only amount-related check is `require(amount <= balance)` at L138, which passes when `amount = 0`. A zero-amount transfer completes fully, emitting a `Transfer(msg.sender, from, to, id, 0)` event at L145. There is no economic harm from the zero-amount transfer itself, but the spurious event emission enables gas-cheap log pollution and may interfere with off-chain systems that process every `Transfer` event as an accounting update.

**Impact**:
- Zero-amount transfers succeed and emit `Transfer` events, creating event log noise.
- Automated systems that process each `Transfer` event may perform unnecessary off-chain work for events with zero economic content.

**Recommendation**:
Add `require(amount > 0, ERC7540FungibilityInvalidInput())` at the start of `transferShares`.

---

### [I-04] pending() Lacks tokenExists Guard [CONTESTED]

**Severity**: Informational
**Location**: `ERC7540Fungibility.sol:L373-387`

**Description**:
The `pending(uint256 tokenId)` public view function at L373 reads `tokens[tokenId]` without a `tokenExists` check. For a cancelled tokenId (where the struct persists per L-01), the function proceeds to query the vault's `pendingDepositRequest` or `pendingRedeemRequest` for the delegate address. Since the delegate no longer controls the vault request after cancellation, the vault returns 0 — so `pending()` returns `false` for a cancelled token. This return value is technically accurate (nothing is pending from the delegate's perspective) but ambiguous: callers cannot distinguish between "cancelled and done", "fulfilled and claimable", or "never existed" states using `pending()` alone.

**Impact**:
- Callers using `pending() == false` as a readiness signal may attempt `redeem()` on a cancelled token, which will fail due to zero ERC-6909 balance.
- Off-chain systems cannot determine a token's full lifecycle state from `pending()` alone.

**Recommendation**:
Add `tokenExists(tokenId)` as a guard to `pending()`, causing it to revert for non-existent or cancelled tokens. Alternatively, introduce a `status(uint256 tokenId)` view returning an enum of `{PENDING, CLAIMABLE, CANCELLED}` to provide unambiguous lifecycle information.

---

### [I-05] Unused Math Import [VERIFIED]

**Severity**: Informational
**Location**: `ERC7540Fungibility.sol:L7`

**Description**:
Line 7 imports `Math` from OpenZeppelin's `utils/math/Math.sol`. A complete search of the contract body finds no invocation of any `Math` library function (`Math.mulDiv`, `Math.min`, `Math.max`, etc.). The import is unused, adding an unnecessary stale dependency and minor additional bytecode to the compiled contract.

**Impact**:
- Minor unnecessary bytecode overhead from an unused import.
- Potential confusion for reviewers expecting the library to be actively used somewhere in the logic.

**Recommendation**:
Remove the unused import:
```solidity
// Remove this line:
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
```

---

### [I-06] Missing Zero-Amount Check in redeem() [VERIFIED]

**Severity**: Informational
**Location**: `ERC7540Fungibility.sol:L389-410`

**Description**:
The `redeem()` function at L389 does not validate that `shares > 0`. With `shares = 0`: `require(0 <= balance)` at L400 passes for any non-negative balance; `totalSupply[tokenId] -= 0` at L403 is a no-op; the vault is called with 0 shares via `claim(token, 0, receiver)`; and `Redeem(tokenId, owner, receiver, assets, msg.sender)` is emitted at L409 regardless of the vault's response. For vaults that silently accept a zero-share redeem and return 0 assets, the full flow completes without error, emitting a `Redeem` event that records a zero-value transaction with no economic effect.

**Impact**:
- A zero-share `redeem()` emits a `Redeem` event with 0 assets and 0 shares, potentially misleading off-chain indexers or volume metrics.
- Vault implementations that reject zero-share redeems will revert, but the check happens inside the vault rather than in ERC7540Fungibility.

**Recommendation**:
Add `require(shares > 0, ERC7540FungibilityInvalidInput())` at the start of `redeem()`.

---

### [I-07] Tokens Sent to Predicted Delegate Address Are Permanently Locked [VERIFIED]

**Severity**: Informational
**Location**: `ERC7540Fungibility.sol` (multiple — delegate deployment and prediction logic)

**Description**:
The `_tokenId` counter increments monotonically (L273: `tokenId = ++_tokenId`). The delegate for the next tokenId is deployed at a deterministic CREATE2 address computable by anyone who knows the current value of `_tokenId`. Before any request function mints that tokenId, this address is an undeployed empty address. Any tokens or ETH sent to the predicted delegate address before deployment are unrecoverable: once the Delegate contract is deployed at that address, it contains no arbitrary token sweep function. The only mechanism to move tokens out of a delegate is through ERC7540Fungibility's vault interaction flows, which operate exclusively on the vault request — not on arbitrary tokens sitting in the delegate.

**Impact**:
- Any user or contract that accidentally sends assets to a predicted-but-not-yet-deployed delegate address permanently loses those assets.
- The predictable address makes accidental sends more plausible than for a randomly generated address.

**Recommendation**:
Document clearly that predicted delegate addresses should not be used as deposit targets. Consider adding a `rescueToken(uint256 tokenId, address token, address recipient)` function on the Delegate contract, callable only by the ERC7540Fungibility owner, to recover accidentally sent tokens from delegates.

---

### [I-08] redeem() owner Parameter Not Tied to Token Struct [VERIFIED]

**Severity**: Informational
**Location**: `ERC7540Fungibility.sol:L389-410`

**Description**:
The `redeem()` function accepts an `owner` parameter used for the `ownerOrOperator(owner)` access check and the `balanceOf[owner][tokenId]` balance burn. This `owner` is structurally decoupled from `tokens[tokenId].owner`. A caller can supply any `owner` address for which they have operator access — burning that address's ERC-6909 balance without any requirement that `owner == tokens[tokenId].owner`. This means the `Redeem` event's `owner` field may not reflect the entity recorded as the vault request's owner in the `Token` struct.

**Impact**:
- Off-chain indexers correlating `Redeem` events with `tokens[tokenId].owner` from the struct will observe mismatches when `owner != tokens[tokenId].owner`.
- Zero-share `redeem()` calls emit misleading `Redeem` events attributing phantom vault actions to arbitrary owner addresses.
- No direct fund loss; this is an observability and interface coherence issue.

**Recommendation**:
Consider adding `require(owner == tokens[tokenId].owner || isOperator[tokens[tokenId].owner][owner])` to enforce that the `owner` parameter reflects the actual token struct's ownership lineage. Also add `require(shares > 0)` (see I-06) to prevent zero-share event emissions.

---

## Priority Remediation Order

1. **H-01**: Fix claimDeposit selector — all deposit claim functionality is broken; immediate (permanent fund lock).
2. **M-01**: Add safeApprove to requestRedeem — all new redeem requests revert unconditionally; immediate (complete DoS).
3. **M-05**: Add receiver != address(0) checks to all four creation functions — immediate (permanent lock on user error or malicious operator).
4. **M-02**: Query pending amount after transfer in transferDeposit/transferRedeem — before launch (supply inflation via malicious vault).
5. **M-06**: Check claimable == 0 before cancel — before launch (orphaned assets on partial fulfillment).
6. **M-03**: Add vault allowlist or balance delta accounting — before launch (operator drain via malicious vault).
7. **M-04**: Use vault.mint instead of deposit for claims — before launch (exchange rate unfairness across ERC-6909 holders).
8. **M-07**: Add claimable check as secondary readiness oracle in pending() — before launch (permanent redeem DoS via always-pending vault).

---

## Appendix A: Internal Audit Traceability

> This appendix maps internal pipeline IDs to report IDs for audit team reference. It is not required for the client.

### Master Finding Index

| Report ID | Internal Hypothesis | Verification | Agent Sources |
|-----------|-------------------|--------------|---------------|
| H-01 | H-1 | VERIFIED [POC-PASS] | Multiple breadth + depth agents, Skeptic-Judge |
| M-01 | H-2 | VERIFIED [POC-PASS] | Breadth agents, depth agent |
| M-02 | H-3 | VERIFIED [POC-PASS] | Breadth agents, depth agent |
| M-03 | H-4 | VERIFIED [POC-PASS] | Specialized depth agent |
| M-04 | H-6 | VERIFIED [POC-PASS] | Breadth + depth agents |
| M-05 | H-7 | VERIFIED [POC-PASS] | Depth + breadth agents |
| M-06 | H-8 | VERIFIED [POC-PASS] | Multiple agents |
| M-07 | H-21 | VERIFIED [POC-PASS] | Depth agent |
| L-01 | H-9 | VERIFIED [CODE-TRACE] | Multiple agents |
| L-02 | H-10 | VERIFIED [CODE-TRACE] | Depth agents |
| L-03 | H-11 | VERIFIED [CODE-TRACE] | Depth agent |
| L-04 | H-12 | VERIFIED [CODE-TRACE] | Breadth + depth agents |
| L-05 | H-13 | VERIFIED [CODE-TRACE] | Breadth agents |
| L-06 | H-14 | VERIFIED [CODE-TRACE] | Breadth agents |
| L-07 | H-15 | CONTESTED [CODE-TRACE] | Breadth agents |
| L-08 | H-17 | CONTESTED [CODE-TRACE] | Breadth agents |
| L-09 | H-18 | VERIFIED [CODE-TRACE] | Breadth + depth agents |
| L-10 | H-19 | CONTESTED [CODE-TRACE] | Breadth agents |
| L-11 | H-20 | VERIFIED [CODE-TRACE] | Depth agent |
| L-12 | H-22 | VERIFIED [CODE-TRACE] | Depth agent |
| L-13 | H-23 | VERIFIED [CODE-TRACE] | Breadth agents |
| L-14 | H-24 | VERIFIED [CODE-TRACE] | Breadth agents |
| L-15 | H-39 | VERIFIED [CODE-TRACE] | Breadth + depth agents |
| L-16 | H-40 | VERIFIED [CODE-TRACE] | Depth agents |
| L-17 | H-32 | VERIFIED [CODE-TRACE] | Chain analysis (PROVEN(Medium) → Low) |
| L-18 | H-33 | VERIFIED [CODE-TRACE] | Chain analysis (PROVEN(Medium) → Low) |
| L-19 | H-34 | VERIFIED [CODE-TRACE] | Chain analysis (PROVEN(Medium) → Low) |
| L-20 | H-35 | VERIFIED [CODE-TRACE] | Chain analysis (PROVEN(Medium) → Low) |
| L-21 | H-38 | VERIFIED [CODE-TRACE] | Depth agent (PROVEN(Medium) → Low) |
| L-22 | H-5 | VERIFIED [POC-PASS] | Multiple agents (trust assumption → Low) |
| I-01 | H-25 | VERIFIED | Breadth agents |
| I-02 | H-26 | VERIFIED | Breadth agents |
| I-03 | H-27 | VERIFIED | Breadth agents |
| I-04 | H-28 | CONTESTED | Breadth agents |
| I-05 | H-29 | VERIFIED | Breadth agents |
| I-06 | H-30 | VERIFIED | Breadth agents |
| I-07 | H-31 | VERIFIED | Breadth agents |
| I-08 | H-37 | VERIFIED | Depth agent |

### Excluded Findings

| Internal ID | Severity | Title | Exclusion Reason |
|-------------|----------|-------|-----------------|
| H-16 | Low | CEI violation in requestDeposit/requestRedeem | FALSE_POSITIVE — tokenExists blocks reentrancy |
| CH-2 | Low | Residual approval + FoT chain | FALSE_POSITIVE — FoT makes approval less exploitable |
| SLITHER-2 | Info | ownerOrOperator modifier unused | FALSE_POSITIVE — modifier used in 5 functions |
| H-36 | Info | ERC-8161 asymmetric interface check | FALSE_POSITIVE — design intent per NatSpec |