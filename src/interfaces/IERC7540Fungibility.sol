// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IERC7540Fungibility
 *
 * @notice Coordinator that wraps pending ERC-7540 vault requests as
 *         fungible ERC-6909 claim tokens. Each wrapped request is
 *         identified by a (claimToken, tokenId) pair.
 *
 * @dev    A separate `ClaimToken` contract is deployed lazily per
 *         (vault, kind) pair, where kind is either deposit or redeem.
 *         Each tokenId on a ClaimToken is backed 1:1 by an isolated
 *         delegate clone that holds the underlying vault request as
 *         its sole controller.
 */
interface IERC7540Fungibility {
  // =========================================================================
  // Errors
  // =========================================================================

  /// @notice Thrown when the caller is neither the owner/controller nor an approved operator.
  error ERC7540FungibilityUnauthorized();

  /// @notice Thrown when an input is invalid (zero address, zero amount, etc).
  error ERC7540FungibilityInvalidInput();

  /// @notice Thrown when the (claimToken, tokenId) pair does not correspond to a known request.
  error ERC7540FungibilityTokenNotFound(address claimToken, uint256 tokenId);

  /// @notice Thrown when a cancel cannot proceed because the supply has been
  ///         split or the underlying vault request is no longer fully pending.
  error ERC7540FungibilityCancelNotAllowed(address claimToken, uint256 tokenId);

  /// @notice Thrown when a target contract does not support the required ERC-165 interface.
  error ERC7540FungibilityInterfaceNotSupported(address addr, bytes4 interfaceId);

  /// @notice Thrown when the holder does not have enough claim-token balance to redeem the requested amount.
  error ERC7540FungibilityInsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 id);

  // =========================================================================
  // Events
  // =========================================================================

  /// @notice Emitted when an operator approval on this coordinator is set or revoked.
  event OperatorSet(address indexed caller, address indexed operator, bool approved);

  /// @notice Emitted when an existing pending deposit request is wrapped into ERC-6909 claim tokens.
  event TransferDeposit(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed vault,
    address owner,
    uint256 requestId,
    address caller
  );

  /// @notice Emitted when an existing pending redeem request is wrapped into ERC-6909 claim tokens.
  event TransferRedeem(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed vault,
    address owner,
    uint256 requestId,
    address caller
  );

  /// @notice Emitted when a new deposit request is originated and wrapped into ERC-6909 claim tokens.
  event RequestDeposit(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed vault,
    address owner,
    uint256 assets,
    address caller
  );

  /// @notice Emitted when a wrapped, fulfilled request is partially or fully claimed against its vault.
  event Deposit(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed owner,
    address receiver,
    uint256 shares,
    uint256 assets,
    address caller
  );

  /// @notice Emitted when a new redeem request is originated and wrapped into ERC-6909 claim tokens.
  event RequestRedeem(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed vault,
    address owner,
    uint256 shares,
    address caller
  );

  /// @notice Emitted when a wrapped, fulfilled request is partially or fully claimed against its vault.
  event Redeem(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed owner,
    address receiver,
    uint256 shares,
    uint256 assets,
    address caller
  );

  /// @notice Emitted when a wrapped pending request is cancelled and its vault control returned to a chosen controller.
  event Cancel(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed owner,
    address controller,
    address caller
  );

  // =========================================================================
  // Configuration
  // =========================================================================

  /// @notice Address of the delegate implementation cloned per (claimToken, tokenId).
  function DELEGATE() external view returns (address);

  /// @notice Address of the `ClaimToken` implementation cloned per (vault, kind).
  function CLAIM_TOKEN() external view returns (address);

  /// @notice Returns true if `operator` is approved to act on behalf of `owner` on this coordinator.
  function isOperator(address owner, address operator) external view returns (bool);

  // =========================================================================
  // State
  // =========================================================================

  /**
   * @notice Computes the deterministic address of the (vault, deposit)
   *         `ClaimToken` for `vault`.
   *
   * @dev    The address is derived from the CREATE2 salt and the clone's
   *         immutable args `(orchestrator, vault, deposit)`. It is returned
   *         whether or not the `ClaimToken` has been deployed, so a non-zero
   *         result does NOT imply deployment — test `claimToken.code.length`
   *         to check for that, or call `initializeDepositClaimToken` to deploy.
   *
   * @param  vault      the vault whose deposit `ClaimToken` address is computed
   *
   * @return claimToken the deterministic (vault, deposit) `ClaimToken` address
   */
  function depositClaimToken(address vault) external view returns (address claimToken);

  /**
   * @notice Computes the deterministic address of the (vault, redeem)
   *         `ClaimToken` for `vault`.
   *
   * @dev    The address is derived from the CREATE2 salt and the clone's
   *         immutable args `(orchestrator, vault, redeem)`. It is returned
   *         whether or not the `ClaimToken` has been deployed, so a non-zero
   *         result does NOT imply deployment — test `claimToken.code.length`
   *         to check for that, or call `initializeRedeemClaimToken` to deploy.
   *
   * @param  vault      the vault whose redeem `ClaimToken` address is computed
   *
   * @return claimToken the deterministic (vault, redeem) `ClaimToken` address
   */
  function redeemClaimToken(address vault) external view returns (address claimToken);

  /**
   * @notice Deploys the (vault, deposit) `ClaimToken` for `vault`, or returns
   *         the existing one if it has already been deployed.
   *
   * @dev    Deploys a deterministic clone at `predictDepositClaimToken(vault)`
   *         via `cloneDeterministicWithImmutableArgs` with immutable args
   *         `(orchestrator, vault, deposit)`. Idempotent: a second call for the
   *         same `vault` returns the existing address without redeploying. The
   *         returned address always has code on success. Normally invoked
   *         lazily on the first deposit wrap or origination for `vault`, but may
   *         be called directly to pre-deploy.
   *
   * @param  vault      the vault whose deposit `ClaimToken` is being deployed
   *
   * @return claimToken the (vault, deposit) `ClaimToken` contract
   */
  function initializeDepositClaimToken(address vault) external returns (address claimToken);

  /**
   * @notice Deploys the (vault, redeem) `ClaimToken` for `vault`, or returns
   *         the existing one if it has already been deployed.
   *
   * @dev    Deploys a deterministic clone at `predictRedeemClaimToken(vault)`
   *         via `cloneDeterministicWithImmutableArgs` with immutable args
   *         `(orchestrator, vault, redeem)`. Idempotent: a second call for the
   *         same `vault` returns the existing address without redeploying. The
   *         returned address always has code on success. Normally invoked
   *         lazily on the first redeem wrap or origination for `vault`, but may
   *         be called directly to pre-deploy.
   *
   * @param  vault      the vault whose redeem `ClaimToken` is being deployed
   *
   * @return claimToken the (vault, redeem) `ClaimToken` contract
   */
  function initializeRedeemClaimToken(address vault) external returns (address claimToken);

  // =========================================================================
  // Wrapping existing pending vault requests (ERC-8161)
  // =========================================================================

  /**
   * @notice Wraps an existing pending deposit request into fungible ERC-6909 claim tokens.
   *
   * @dev    `vault` MUST implement `IERC7540Deposit` and `IERC8161DepositTransferable`.
   *         msg.sender MUST be `controller` or its operator on this contract,
   *         and this contract MUST be approved as an operator of `controller` on `vault`
   *         so that the pending request can be transferred to a fresh delegate via ERC-8161.
   *
   * @param  vault      the vault holding the pending request
   * @param  requestId  the vault-side request identifier
   * @param  controller the current controller of the request on the vault
   * @param  receiver   the recipient of the minted ERC-6909 tokens
   *
   * @return claimToken the (vault, deposit) `ClaimToken` contract; deployed lazily on first use
   * @return tokenId    the newly minted ERC-6909 token id
   */
  function transferDeposit(
    address vault,
    uint256 requestId,
    address controller,
    address receiver
  ) external returns (address claimToken, uint256 tokenId);

  /**
   * @notice Wraps an existing pending redeem request into fungible ERC-6909 claim tokens.
   *
   * @dev    `vault` MUST implement `IERC7540Redeem` and `IERC8161RedeemTransferable`.
   *         msg.sender MUST be `controller` or its operator on this contract,
   *         and this contract MUST be approved as an operator of `controller` on `vault`
   *         so that the pending request can be transferred to a fresh delegate via ERC-8161.
   *
   * @param  vault      the vault holding the pending request
   * @param  requestId  the vault-side request identifier
   * @param  controller the current controller of the request on the vault
   * @param  receiver   the recipient of the minted ERC-6909 tokens
   *
   * @return claimToken the (vault, redeem) `ClaimToken` contract; deployed lazily on first use
   * @return tokenId    the newly minted ERC-6909 token id
   */
  function transferRedeem(
    address vault,
    uint256 requestId,
    address controller,
    address receiver
  ) external returns (address claimToken, uint256 tokenId);

  // =========================================================================
  // Originating new vault requests
  // =========================================================================

  /**
   * @notice Originates a new deposit request on `vault` from `owner`'s assets
   *         and wraps it into fungible ERC-6909 claim tokens.
   *
   * @dev    `vault` MUST implement `IERC7540Deposit`. ERC-8161 support is
   *         not required because the request is opened directly through a
   *         freshly deployed per-token delegate.
   *
   *         msg.sender MUST be `owner` or its operator on this contract.
   *         `owner` MUST have approved this contract on the vault's
   *         underlying asset for at least `assets`.
   *
   * @param  vault    the vault to deposit into
   * @param  assets   the amount of underlying asset to pull from `owner`
   * @param  owner    the source of the underlying assets
   * @param  receiver the recipient of the minted ERC-6909 tokens
   *
   * @return claimToken the (vault, deposit) `ClaimToken` contract; deployed lazily on first use
   * @return tokenId    the newly minted ERC-6909 token id
   */
  function requestDeposit(
    address vault,
    uint256 assets,
    address owner,
    address receiver
  ) external returns (address claimToken, uint256 tokenId);

  /**
   * @notice Originates a new redeem request on `vault` from `owner`'s vault shares
   *         and wraps it into fungible ERC-6909 claim tokens.
   *
   * @dev    `vault` MUST implement `IERC7540Redeem`. ERC-8161 support is
   *         not required because the request is opened directly through a
   *         freshly deployed per-token delegate.
   *
   *         msg.sender MUST be `owner` or its operator on this contract.
   *         `owner` MUST have approved this contract on the vault's
   *         share token for at least `shares`.
   *
   * @param  vault    the vault to redeem against
   * @param  shares   the amount of vault shares to pull from `owner`
   * @param  owner    the source of the vault shares
   * @param  receiver the recipient of the minted ERC-6909 tokens
   *
   * @return claimToken the (vault, redeem) `ClaimToken` contract; deployed lazily on first use
   * @return tokenId    the newly minted ERC-6909 token id
   */
  function requestRedeem(
    address vault,
    uint256 shares,
    address owner,
    address receiver
  ) external returns (address claimToken, uint256 tokenId);

  // =========================================================================
  // Request status
  // =========================================================================

  /**
   * @notice Returns the amount of assets still pending on the vault for a
   *         wrapped deposit request.
   *
   * @dev    Reads `pendingDepositRequest` on the underlying vault for the
   *         delegate backing (claimToken, tokenId). `claimToken` MUST be a
   *         (vault, deposit) `ClaimToken` whose vault implements `IERC7540Deposit`.
   *
   * @param  claimToken the deposit `ClaimToken` contract for the wrapped request
   * @param  tokenId    the ERC-6909 token id of the wrapped request
   *
   * @return assets the amount of underlying assets still pending on the vault
   */
  function pendingDepositRequest(address claimToken, uint256 tokenId) external view returns (uint256 assets);

  /**
   * @notice Returns the amount of assets claimable on the vault for a wrapped
   *         deposit request.
   *
   * @dev    Reads `claimableDepositRequest` on the underlying vault for the
   *         delegate backing (claimToken, tokenId). `claimToken` MUST be a
   *         (vault, deposit) `ClaimToken` whose vault implements `IERC7540Deposit`.
   *
   * @param  claimToken the deposit `ClaimToken` contract for the wrapped request
   * @param  tokenId    the ERC-6909 token id of the wrapped request
   *
   * @return assets the amount of underlying assets now claimable on the vault
   */
  function claimableDepositRequest(address claimToken, uint256 tokenId) external view returns (uint256 assets);

  /**
   * @notice Returns the amount of shares still pending on the vault for a
   *         wrapped redeem request.
   *
   * @dev    Reads `pendingRedeemRequest` on the underlying vault for the
   *         delegate backing (claimToken, tokenId). `claimToken` MUST be a
   *         (vault, redeem) `ClaimToken` whose vault implements `IERC7540Redeem`.
   *
   * @param  claimToken the redeem `ClaimToken` contract for the wrapped request
   * @param  tokenId    the ERC-6909 token id of the wrapped request
   *
   * @return shares the amount of vault shares still pending on the vault
   */
  function pendingRedeemRequest(address claimToken, uint256 tokenId) external view returns (uint256 shares);

  /**
   * @notice Returns the amount of shares claimable on the vault for a wrapped
   *         redeem request.
   *
   * @dev    Reads `claimableRedeemRequest` on the underlying vault for the
   *         delegate backing (claimToken, tokenId). `claimToken` MUST be a
   *         (vault, redeem) `ClaimToken` whose vault implements `IERC7540Redeem`.
   *
   * @param  claimToken the redeem `ClaimToken` contract for the wrapped request
   * @param  tokenId    the ERC-6909 token id of the wrapped request
   *
   * @return shares the amount of vault shares now claimable on the vault
   */
  function claimableRedeemRequest(address claimToken, uint256 tokenId) external view returns (uint256 shares);

  // =========================================================================
  // Exit
  // =========================================================================

  /**
   * @notice Cancels a wrapped pending request, transferring control of the
   *         underlying vault request to `controller` and burning the entire
   *         ERC-6909 supply.
   *
   * @dev    Only permitted while the request is fully pending and the
   *         owner still owns the entire ERC-6909 supply for
   *         (claimToken, tokenId). The underlying vault MUST implement
   *         the appropriate ERC-8161 transferable extension.
   *
   *         msg.sender MUST be the holder or its operator on this contract.
   *
   * @param  claimToken the `ClaimToken` contract for the wrapped request
   * @param  tokenId    the ERC-6909 token id of the wrapped request
   * @param  owner      the owner to cancel the claim from
   * @param  controller the address that becomes the new controller of the vault request
   */
  function cancel(address claimToken, uint256 tokenId, address owner, address controller) external;

  /**
   * @notice Claims `assets` of a fulfilled wrapped deposit request, burning the
   *         corresponding ERC-6909 balance and delivering the resulting vault
   *         shares to `receiver`.
   *
   * @dev    The underlying vault deposit request MUST no longer be pending. This
   *         calls `deposit` on the vault through the per-token delegate and
   *         delivers vault shares to `receiver`. `claimToken` MUST be the
   *         (vault, deposit) `ClaimToken`. Partial claims are supported.
   *
   *         msg.sender MUST be `owner` or its operator on this contract.
   *
   * @param  claimToken the deposit `ClaimToken` contract for the wrapped request
   * @param  tokenId    the ERC-6909 token id
   * @param  assets     the amount of ERC-6909 balance to burn and claim against
   * @param  receiver   the recipient of the vault shares
   * @param  owner      the holder of the ERC-6909 balance being claimed
   *
   * @return shares the amount of vault shares delivered to `receiver`
   */
  function deposit(
    address claimToken,
    uint256 tokenId,
    uint256 assets,
    address receiver,
    address owner
  ) external returns (uint256 shares);

  /**
   * @notice Claims `shares` of a fulfilled wrapped redeem request, burning the
   *         corresponding ERC-6909 balance and delivering the resulting vault
   *         assets to `receiver`.
   *
   * @dev    The underlying vault redeem request MUST no longer be pending. This
   *         calls `redeem` on the vault through the per-token delegate and
   *         delivers underlying assets to `receiver`. `claimToken` MUST be the
   *         (vault, redeem) `ClaimToken`. Partial claims are supported.
   *
   *         msg.sender MUST be `owner` or its operator on this contract.
   *
   * @param  claimToken the redeem `ClaimToken` contract for the wrapped request
   * @param  tokenId    the ERC-6909 token id
   * @param  shares     the amount of ERC-6909 balance to burn and claim against
   * @param  receiver   the recipient of the vault assets
   * @param  owner      the holder of the ERC-6909 balance being claimed
   *
   * @return assets the amount of vault assets delivered to `receiver`
   */
  function redeem(
    address claimToken,
    uint256 tokenId,
    uint256 shares,
    address receiver,
    address owner
  ) external returns (uint256 assets);

  // =========================================================================
  // Operator
  // =========================================================================

  /**
   * @notice Sets or revokes operator privileges for `spender` on the caller's behalf.
   *
   * @dev    An operator may originate, wrap, cancel, and redeem on behalf of msg.sender.
   *
   * @param  spender  the account being granted or revoked operator privileges
   * @param  approved true to grant, false to revoke
   *
   * @return success always true
   */
  function setOperator(address spender, bool approved) external returns (bool success);

  // =========================================================================
  // Metadata
  // =========================================================================

  function requests(address claimToken, uint256 tokenId) external view returns (address vault, uint256 requestId);

  function delegateOf(address claimToken, uint256 tokenId) external view returns (address delegate);
}
