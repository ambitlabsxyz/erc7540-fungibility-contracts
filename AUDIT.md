# ERC7540Fungibility — Audit Findings

Findings grouped by type. Locations use `src/` paths. Severities are shown where flagged in the source data.

## Summary

| # | Finding | Location | Severity |
| --- | --- | --- | --- |
| 1 | Partially fulfilled requests have no exit path | `ERC7540Fungibility.sol:284` | High (confirmed) |
| 2 | Dust-griefing the redeem gate | `ERC7540Fungibility.sol:341` | High (plausible) |
| 3 | Checks-effects-interactions violation enables reentrancy | `ERC7540Fungibility.sol:180` | — |
| 4 | Claim-token metadata read from the wrong contract for ERC-7575 | `ClaimToken.sol:73` | — |
| 5 | Transfer wraps trust the vault to move the full pending balance | `ERC7540Fungibility.sol:122` | — |
| 6 | Fixed claim supply strands the last redeemer on any shortfall | `ERC7540Fungibility.sol:356` | — |
| 7 | Deposit/redeem kind encoded as bare 0/1 literals | `ERC7540Fungibility.sol:64` | — |
| 8 | Delegate salt expression duplicated across seven sites | `ERC7540Fungibility.sol:120` | — |
| 9 | Redundant per-token vault storage | `ERC7540Fungibility.sol:34` | — |
| 10 | Deploy script re-hardcodes the CreateX factory address | `script/Deploy.s.sol:50` | — |

## Security and behavioral issues

### 1. Partially fulfilled requests have no exit path

`src/ERC7540Fungibility.sol:284` · High, confirmed

`cancel()` requires the delegate's vault-side pending amount to exactly equal the full claim supply, while `redeem()` reverts whenever any amount is pending. ERC-7540 explicitly permits partial fulfillment, so a request fulfilled 40 of 100 can be neither cancelled (60 ≠ 100) nor redeemed (pending > 0). Funds stay stuck until the vault happens to drive pending to exactly zero. On main, `cancel()` only required the request to still be pending, so this escape hatch existed and the diff removed it.

**Failure scenario.** Alice wraps a 100e6 deposit request. The vault partially fulfills 40e6 (pending = 60e6), or an attacker adds a 1-wei dust request (pending = 100e6 + 1). `cancel()` reverts because pending ≠ balance, and `redeem()` reverts because `pending()` is true. Funds remain locked until the vault brings the delegate's pending to exactly zero, which a griefer can prevent indefinitely.

### 2. Dust-griefing the redeem gate

`src/ERC7540Fungibility.sol:341` · High, plausible

`redeem()` is blocked for all holders whenever the vault reports any pending amount for the per-token delegate. The delegate address is deterministically predictable, and ERC-7540 lets anyone open a request naming an arbitrary controller. On vaults with shared request IDs (requestId 0 per controller, the common pattern), an attacker can create that pending themselves. Once claim tokens are split among holders, `cancel()` is unavailable by design, so there is no recovery.

**Failure scenario.** On a shared-requestId vault, the attacker calls `vault.requestDeposit(1, delegate, attacker)`, where `delegate = DELEGATE.predict(keccak256(abi.encode(claimToken, tokenId)))`. `pending()` returns true, and every holder's `redeem()` reverts with `ERC7540FungibilityPending`. Repeated 1-wei dust locks all claimable funds indefinitely.

*Shared root cause with #1:* both gate claims on a controller-scoped, attacker-influenceable pending amount instead of tracking what the wrapper itself deposited.

### 3. Checks-effects-interactions violation enables reentrancy

`src/ERC7540Fungibility.sol:180`

In `requestDeposit` and `requestRedeem`, claim tokens are minted and `request.vault` is set before the external `safeTransferFrom` of a user-supplied token, and `request.requestId` is stored only afterward. During a token-transfer hook the `pending()` guard is therefore bypassed, because `requestId` is still 0 and reads as no pending. This is a genuine checks-effects-interactions violation with no reentrancy guard.

**Failure scenario.** The vault asset is a hook-bearing (ERC-777-style) token. During the owner-to-delegate transfer hook the attacker reenters `redeem()`. `pending()` returns false because `pendingDepositRequest(0, delegate)` is 0, the burn succeeds, and the delegate calls `vault.deposit` with nothing claimable. A compliant vault reverts and unwinds this, but any lenient vault leaks value.

### 4. Claim-token metadata read from the wrong contract for ERC-7575

`src/ClaimToken.sol:73`

`decimals()`, `name()`, and `symbol()` read ERC-20 metadata from the vault contract. For ERC-7575 vaults (the case this diff explicitly added support for in `requestRedeem`) the share token is an external contract and the vault typically has no `decimals()`, so solady's `MetadataReaderLib` returns 0. It should read `IERC7575(vault).share()` metadata when the vault supports 7575.

**Failure scenario.** `requestRedeem` against a 7575 vault with an external 18-decimal share token mints share-denominated claims whose `decimals()` reports 0. Wallets and indexers display a 5e18-share claim as 5,000,000,000,000,000,000 units, mispricing the transferable claim tokens.

### 5. Transfer wraps trust the vault to move the full pending balance

`src/ERC7540Fungibility.sol:122`

`transferDeposit` and `transferRedeem` mint claim tokens equal to the pending amount read before the ERC-8161 transfer, and never verify after the transfer that the delegate actually controls that amount. `cancel()` does re-verify; these paths do not. A post-transfer `require(pendingDepositRequest(requestId, delegate) == assets)` would make the wrap atomic-or-revert.

**Failure scenario.** A vault that passes ERC-165 but deviates from ERC-8161's requirement to transfer the entire pending balance (fee, rounding, tranches) leaves claim holders holding receipts for 100 backed by 95. The last redeemers' vault calls revert and their claim tokens are worthless.

### 6. Fixed claim supply strands the last redeemer on any shortfall

`src/ERC7540Fungibility.sol:356`

Claim-token supply is fixed at wrap time and never reconciled with the vault's claimable amount. Any vault-side fulfillment fee or rounding shortfall makes the last redeemer's claim tokens permanently unredeemable, and excess claimable is stranded in the delegate with no sweep.

**Failure scenario.** 100 claim tokens are minted. The vault charges a fulfillment fee and reports claimable = 99. Holders redeem 99, and the final 1-token holder's `vault.deposit(1, ...)` reverts forever. `requests[claimToken][tokenId]` can never be cleaned up because `totalSupply` never reaches 0.

## Code quality and gas

### 7. Deposit/redeem kind encoded as bare 0/1 literals

`src/ERC7540Fungibility.sol:64`

The deposit/redeem kind is encoded as bare 0/1 literals at four `abi.encode` sites (and decoded as `kind == 0` in ClaimToken), and the deposit and redeem function pairs are copy-paste duplicates differing only in that literal. There is no shared enum, constant, or kind-parameterized helper.

**Failure scenario.** Transposing a single 0/1 during a future edit compiles cleanly but derives a different CREATE2 address, wrapping deposit requests under the redeem ClaimToken. `redeem()` later dispatches `IERC4626.redeem` against a deposit request and strands the claim. The compiler cannot cross-check the six-plus literal sites across the two files.

### 8. Delegate salt expression duplicated across seven sites

`src/ERC7540Fungibility.sol:120`

The delegate salt expression `keccak256(abi.encode(claimToken, tokenId))` is copy-pasted inline at seven sites (four deploy-side, three predict-side) instead of one private helper.

**Failure scenario.** A typo in one occurrence during refactoring (for example `abi.encodePacked` in one spot) makes deploy-time and predict-time salts diverge, so `cancel`, `pending`, and `redeem` address a delegate that holds nothing and the vault request is permanently stranded. A single `delegateSalt()` helper makes divergence impossible.

### 9. Redundant per-token vault storage

`src/ERC7540Fungibility.sol:34`

`requests[claimToken][tokenId].vault` stores the identical vault address for every `tokenId` of a given ClaimToken, duplicating the vault already baked into the clone's immutable args (`ClaimToken.vault()`). Only `requestId` plus an existence flag are genuinely per-token.

**Failure scenario.** Every request creation pays a roughly 20k-gas cold SSTORE writing the same 20-byte vault into a fresh slot, and the codebase carries two sources of truth for a claim token's vault that future code paths can read inconsistently.
 