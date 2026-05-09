// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IERC7540Fungibility {
  // =========================================================================
  // ERC7540Fungibility Errors
  // =========================================================================

  error ERC7540FungibilityUnauthorized();
  error ERC7540FungibilityInvalidInput();
  error ERC7540FungibilityTokenNotFound(address claimToken, uint256 tokenId);
  error ERC7540FungibilityCancelNotAllowed(address claimToken, uint256 tokenId);
  error ERC7540FungibilityPending(address claimToken, uint256 tokenId);
  error ERC7540FungibilityInterfaceNotSupported(address addr, bytes4 interfaceId);
  error ERC7540FungibilityInsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 id);

  // =========================================================================
  // Events
  // =========================================================================

  event OperatorSet(address indexed caller, address indexed operator, bool approved);

  event TransferDeposit(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed vault,
    address owner,
    uint256 requestId,
    address caller
  );

  event TransferRedeem(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed vault,
    address owner,
    uint256 requestId,
    address caller
  );

  event RequestDeposit(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed vault,
    address owner,
    uint256 assets,
    address caller
  );

  event RequestRedeem(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed vault,
    address owner,
    uint256 shares,
    address caller
  );

  event Cancel(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed owner,
    address controller,
    address caller
  );

  event Redeem(
    address indexed claimToken,
    uint256 indexed tokenId,
    address indexed owner,
    address receiver,
    uint256 assets,
    address caller
  );
}
