// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC6909, IERC6909Metadata, IERC6909TokenSupply } from "@openzeppelin/contracts/interfaces/IERC6909.sol";

/// @title IERC7540Fungibility
/// @notice Converts pending ERC-7540 async vault requests into fungible ERC-6909 claim tokens.
/// Requests are mapped by their issued token ID. Each token ID represents a single vault request
/// backed by an isolated delegate clone that acts as the controller on the underlying vault.
interface IERC7540Fungibility is IERC165, IERC6909, IERC6909Metadata, IERC6909TokenSupply {
  // =========================================================================
  // ERC-6909 Errors
  // =========================================================================

  error ERC6909InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 id);
  error ERC6909InsufficientAllowance(address spender, uint256 allowance, uint256 needed, uint256 id);
  error ERC6909InvalidApprover(address approver);
  error ERC6909InvalidReceiver(address receiver);
  error ERC6909InvalidSender(address sender);
  error ERC6909InvalidSpender(address spender);

  // =========================================================================
  // ERC7540Fungibility Errors
  // =========================================================================

  error ERC7540FungibilityUnauthorized();
  error ERC7540FungibilityInvalidInput();
  error ERC7540FungibilityTokenNotFound(uint256 tokenId);
  error ERC7540FungibilityCancelNotAllowed(uint256 tokenId);
  error ERC7540FungibilityPending(uint256 tokenId);
  error ERC7540FungibilityInterfaceNotSupported(address addr, bytes4 interfaceId);

  // =========================================================================
  // Events
  // =========================================================================

  event TransferDeposit(
    uint256 indexed tokenId,
    address indexed vault,
    address indexed owner,
    uint256 requestId,
    address caller
  );

  event TransferRedeem(
    uint256 indexed tokenId,
    address indexed vault,
    address indexed owner,
    uint256 requestId,
    address caller
  );

  event RequestDeposit(
    uint256 indexed tokenId,
    address indexed vault,
    address indexed owner,
    uint256 assets,
    address caller
  );

  event RequestRedeem(
    uint256 indexed tokenId,
    address indexed vault,
    address indexed owner,
    uint256 shares,
    address caller
  );

  event Cancel(uint256 indexed tokenId, address indexed controller, address caller);

  event Redeem(
    uint256 indexed tokenId,
    address indexed owner,
    address indexed receiver,
    uint256 assets,
    address caller
  );

  // =========================================================================
  // Functions
  // =========================================================================

  /**
   * @notice Transfers an existing ERC-8161 pending deposit request into the fungibility
   * contract, minting ERC-6909 claim tokens to the receiver.
   *
   * The vault must support IERC7540Deposit and IERC8161DepositTransferable.
   * The caller must be the controller or their operator on this contract.
   * This contract must be set as an operator on the vault for the controller.
   *
   * @param vault The ERC-7540 vault that holds the pending deposit request
   * @param requestId The vault request ID to transfer
   * @param controller The current controller of the request on the vault
   * @param receiver The address that receives ERC-6909 tokens and becomes the token owner
   *
   * @return tokenId The ERC-6909 token ID representing the wrapped request
   */
  function transferDeposit(
    address vault,
    uint256 requestId,
    address controller,
    address receiver
  ) external returns (uint256 tokenId);

  /**
   * @notice Transfers an existing ERC-8161 pending redeem request into the fungibility
   * contract, minting ERC-6909 claim tokens to the receiver.
   *
   * The vault must support IERC7540Redeem and IERC8161RedeemTransferable.
   * The caller must be the controller or their operator on this contract.
   * This contract must be set as an operator on the vault for the controller.
   *
   * @param vault The ERC-7540 vault that holds the pending redeem request
   * @param requestId The vault request ID to transfer
   * @param controller The current controller of the request on the vault
   * @param receiver The address that receives ERC-6909 tokens and becomes the token owner
   *
   * @return tokenId The ERC-6909 token ID representing the wrapped request
   */
  function transferRedeem(
    address vault,
    uint256 requestId,
    address controller,
    address receiver
  ) external returns (uint256 tokenId);

  /**
   * @notice Pulls underlying assets from the owner, originates a new async deposit request
   * on the vault via an isolated delegate, and mints ERC-6909 claim tokens to the receiver.
   *
   * The vault must support IERC7540Deposit.
   * The caller must be the owner or their operator on this contract.
   * The owner must have ERC-20 approval for the underlying asset to this contract.
   *
   * @param vault The ERC-7540 vault to request a deposit on
   * @param assets The amount of underlying assets to deposit
   * @param owner The address whose assets are pulled
   * @param receiver The address that receives ERC-6909 tokens and becomes the token owner
   *
   * @return tokenId The ERC-6909 token ID representing the wrapped request
   */
  function requestDeposit(
    address vault,
    uint256 assets,
    address owner,
    address receiver
  ) external returns (uint256 tokenId);

  /**
   * @notice Pulls vault shares from the owner, originates a new async redeem request
   * on the vault via an isolated delegate, and mints ERC-6909 claim tokens to the receiver.
   *
   * The vault must support IERC7540Redeem.
   * The caller must be the owner or their operator on this contract.
   * The owner must have ERC-20 approval for the vault shares to this contract.
   *
   * @param vault The ERC-7540 vault to request a redeem on
   * @param shares The amount of vault shares to redeem
   * @param owner The address whose vault shares are pulled
   * @param receiver The address that receives ERC-6909 tokens and becomes the token owner
   *
   * @return tokenId The ERC-6909 token ID representing the wrapped request
   */
  function requestRedeem(
    address vault,
    uint256 shares,
    address owner,
    address receiver
  ) external returns (uint256 tokenId);

  /**
   * @notice Cancels a wrapped request by transferring the vault request back to the
   * specified controller via ERC-8161. Burns all ERC-6909 tokens and deletes the request.
   *
   * Only callable by the token owner or their operator.
   * Only allowed if the owner still holds all shares.
   * The vault must support ERC-8161 transferable requests.
   *
   * @param tokenId The ERC-6909 token ID to cancel
   * @param controller The address that receives the vault request back
   */
  function cancel(uint256 tokenId, address controller) external;

  /**
   * @notice Returns whether the underlying vault request is still pending.
   *
   * @param tokenId The ERC-6909 token ID to check
   *
   * @return True if the vault has not yet processed the request
   */
  function pending(uint256 tokenId) external view returns (bool);

  /**
   * @notice Burns ERC-6909 shares and claims the corresponding portion directly from
   * the underlying vault via deposit() or redeem(). Each call executes a partial
   * claim against the vault.
   *
   * The request must not be pending (vault has fulfilled it).
   * Only callable by the owner or their operator.
   * The return amount is determined by the vault's exchange rate at execution time.
   *
   * @param tokenId The ERC-6909 token ID to redeem from
   * @param shares The number of shares to burn
   * @param receiver The address that receives the settled assets or vault shares
   * @param owner The address whose shares are burned
   *
   * @return assets The amount of assets or vault shares transferred to the receiver
   */
  function redeem(uint256 tokenId, uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
