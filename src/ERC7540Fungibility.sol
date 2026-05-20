// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC7540Deposit } from "./interfaces/IERC7540Deposit.sol";
import { IERC7540Redeem } from "./interfaces/IERC7540Redeem.sol";
import { IERC8161DepositTransferable } from "./interfaces/IERC8161DepositTransferable.sol";
import { IERC8161RedeemTransferable } from "./interfaces/IERC8161RedeemTransferable.sol";
import { Delegate } from "@ambitlabs/delegate-contracts/Delegate.sol";
import { DelegateLib } from "@ambitlabs/delegate-contracts/DelegateLib.sol";
import { IERC7540Fungibility } from "./interfaces/IERC7540Fungibility.sol";
import { ClaimToken } from "./ClaimToken.sol";

contract ERC7540Fungibility is IERC7540Fungibility {
  using SafeERC20 for IERC20;
  using DelegateLib for address;
  using DelegateLib for Delegate;

  address public immutable DELEGATE;
  address public immutable CLAIM_TOKEN;

  mapping(address owner => mapping(address operator => bool isOperator)) public isOperator;

  mapping(address vault => address claimToken) depositClaimToken;

  mapping(address vault => address claimToken) redeemClaimToken;

  struct Request {
    address owner;
    address vault;
    uint256 requestId;
  }

  mapping(address claimToken => mapping(uint256 tokenId => Request)) requests;

  constructor(address delegate, address claimToken) {
    require(delegate != address(0), ERC7540FungibilityInvalidInput());
    require(claimToken != address(0), ERC7540FungibilityInvalidInput());
    DELEGATE = delegate;
    CLAIM_TOKEN = claimToken;
  }

  // =========================================================================
  // Modifiers
  // =========================================================================

  modifier ownerOrOperator(address owner) {
    checkOwnerOroperator(owner);
    _;
  }

  function checkOwnerOroperator(address owner) private view {
    require(msg.sender == owner || isOperator[owner][msg.sender], ERC7540FungibilityUnauthorized());
  }

  // =========================================================================
  // ERC7540Fungibility
  // =========================================================================

  function getOrCreateClaimToken(
    mapping(address => address) storage map,
    address vault,
    uint8 kind
  ) private returns (address claimToken) {
    claimToken = map[vault];

    if (address(claimToken) == address(0)) {
      claimToken = map[vault] = Clones.cloneDeterministicWithImmutableArgs(
        CLAIM_TOKEN,
        abi.encode(address(this), vault, kind),
        0
      );
    }
  }

  /// @inheritdoc IERC7540Fungibility
  function transferDeposit(
    address vault,
    uint256 requestId,
    address controller,
    address receiver
  ) external ownerOrOperator(controller) returns (address claimToken, uint256 tokenId) {
    requireInterface(vault, type(IERC7540Deposit).interfaceId);
    requireInterface(vault, type(IERC8161DepositTransferable).interfaceId);
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    uint256 assets = IERC7540Deposit(vault).pendingDepositRequest(requestId, controller);
    require(assets > 0, ERC7540FungibilityInvalidInput());

    claimToken = getOrCreateClaimToken(depositClaimToken, vault, 0);

    tokenId = ClaimToken(claimToken).next();

    Request storage request = requests[claimToken][tokenId];
    request.owner = receiver;
    request.vault = vault;
    request.requestId = requestId;

    ClaimToken(claimToken).mint(receiver, tokenId, assets);

    address payable delegate = DELEGATE.deploy(keccak256(abi.encode(claimToken, tokenId)));

    IERC8161DepositTransferable(vault).transferDepositRequest(requestId, controller, delegate);

    emit TransferDeposit(claimToken, tokenId, vault, request.owner, requestId, msg.sender);
  }

  /// @inheritdoc IERC7540Fungibility
  function transferRedeem(
    address vault,
    uint256 requestId,
    address controller,
    address receiver
  ) external ownerOrOperator(controller) returns (address claimToken, uint256 tokenId) {
    requireInterface(vault, type(IERC7540Redeem).interfaceId);
    requireInterface(vault, type(IERC8161RedeemTransferable).interfaceId);
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    uint256 shares = IERC7540Redeem(vault).pendingRedeemRequest(requestId, controller);
    require(shares > 0, ERC7540FungibilityInvalidInput());

    claimToken = getOrCreateClaimToken(redeemClaimToken, vault, 1);

    tokenId = ClaimToken(claimToken).next();

    Request storage request = requests[claimToken][tokenId];
    request.owner = receiver;
    request.vault = vault;
    request.requestId = requestId;

    ClaimToken(claimToken).mint(receiver, tokenId, shares);

    address payable delegate = DELEGATE.deploy(keccak256(abi.encode(claimToken, tokenId)));

    IERC8161RedeemTransferable(vault).transferRedeemRequest(requestId, controller, delegate);

    emit TransferRedeem(claimToken, tokenId, vault, request.owner, requestId, msg.sender);
  }

  /// @inheritdoc IERC7540Fungibility
  function requestDeposit(
    address vault,
    uint256 assets,
    address owner,
    address receiver
  ) external ownerOrOperator(owner) returns (address claimToken, uint256 tokenId) {
    requireInterface(vault, type(IERC7540Deposit).interfaceId);
    require(assets > 0, ERC7540FungibilityInvalidInput());
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    claimToken = getOrCreateClaimToken(depositClaimToken, vault, 0);

    tokenId = ClaimToken(claimToken).next();

    Request storage request = requests[claimToken][tokenId];
    request.owner = receiver;
    request.vault = vault;

    ClaimToken(claimToken).mint(receiver, tokenId, assets);

    address payable delegate = DELEGATE.deploy(keccak256(abi.encode(claimToken, tokenId)));

    request.requestId = requestDeposit(delegate, vault, assets, receiver);

    emit RequestDeposit(claimToken, tokenId, vault, request.owner, assets, msg.sender);
  }

  function requestDeposit(
    address payable delegate,
    address vault,
    uint256 assets,
    address owner
  ) private returns (uint256 requestId) {
    address asset = IERC4626(vault).asset();

    IERC20(asset).safeTransferFrom(owner, delegate, assets);

    Delegate(delegate).safeApprove(asset, vault, assets);

    bytes memory result = Delegate(delegate).call(
      vault,
      abi.encodeCall(IERC7540Deposit.requestDeposit, (assets, delegate, delegate))
    );

    requestId = abi.decode(result, (uint256));
  }

  /// @inheritdoc IERC7540Fungibility
  function requestRedeem(
    address vault,
    uint256 shares,
    address owner,
    address receiver
  ) external ownerOrOperator(owner) returns (address claimToken, uint256 tokenId) {
    requireInterface(vault, type(IERC7540Redeem).interfaceId);
    require(shares > 0, ERC7540FungibilityInvalidInput());
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    claimToken = getOrCreateClaimToken(redeemClaimToken, vault, 1);

    tokenId = ClaimToken(claimToken).next();

    Request storage request = requests[claimToken][tokenId];
    request.owner = receiver;
    request.vault = vault;

    ClaimToken(claimToken).mint(receiver, tokenId, shares);

    address payable delegate = DELEGATE.deploy(keccak256(abi.encode(claimToken, tokenId)));

    request.requestId = requestRedeem(delegate, vault, shares, receiver);

    emit RequestRedeem(claimToken, tokenId, vault, request.owner, shares, msg.sender);
  }

  function requestRedeem(
    address payable delegate,
    address vault,
    uint256 shares,
    address owner
  ) private returns (uint256 requestId) {
    IERC20(vault).safeTransferFrom(owner, delegate, shares);

    Delegate(delegate).safeApprove(address(vault), vault, shares);

    bytes memory result = Delegate(delegate).call(
      vault,
      abi.encodeCall(IERC7540Redeem.requestRedeem, (shares, delegate, delegate))
    );

    requestId = abi.decode(result, (uint256));
  }

  /// @inheritdoc IERC7540Fungibility
  function cancel(address claimToken, uint256 tokenId, address controller) external {
    require(controller != address(0), ERC7540FungibilityInvalidInput());

    Request storage request = requests[claimToken][tokenId];
    require(request.vault != address(0), ERC7540FungibilityTokenNotFound(claimToken, tokenId));

    // can only cancel if the owner still holds all of the supply
    uint256 balance = ClaimToken(claimToken).balanceOf(request.owner, tokenId);
    require(
      balance == ClaimToken(claimToken).totalSupply(tokenId),
      ERC7540FungibilityCancelNotAllowed(claimToken, tokenId)
    );

    require(msg.sender == request.owner || isOperator[request.owner][msg.sender], ERC7540FungibilityUnauthorized());

    ClaimToken(claimToken).burn(request.owner, tokenId, balance);

    address payable delegate = DELEGATE.predict(keccak256(abi.encode(claimToken, tokenId)));

    if (depositClaimToken[request.vault] == claimToken) {
      requireInterface(request.vault, type(IERC8161DepositTransferable).interfaceId);

      // all shares must still be pending so we avoid partial transfers
      require(
        IERC7540Deposit(request.vault).pendingDepositRequest(request.requestId, delegate) == balance,
        ERC7540FungibilityCancelNotAllowed(claimToken, tokenId)
      );

      Delegate(delegate).call(
        request.vault,
        abi.encodeCall(IERC8161DepositTransferable.transferDepositRequest, (request.requestId, delegate, controller))
      );
    } else {
      requireInterface(request.vault, type(IERC8161RedeemTransferable).interfaceId);

      // all shares must still be pending so we avoid partial transfers
      require(
        IERC7540Redeem(request.vault).pendingRedeemRequest(request.requestId, delegate) == balance,
        ERC7540FungibilityCancelNotAllowed(claimToken, tokenId)
      );

      Delegate(delegate).call(
        request.vault,
        abi.encodeCall(IERC8161RedeemTransferable.transferRedeemRequest, (request.requestId, delegate, controller))
      );
    }

    emit Cancel(claimToken, tokenId, request.owner, controller, msg.sender);

    delete requests[claimToken][tokenId];
  }

  /// @inheritdoc IERC7540Fungibility
  function pending(address claimToken, uint256 tokenId) public view returns (bool) {
    Request storage request = requests[claimToken][tokenId];
    if (request.vault == address(0) || ClaimToken(claimToken).totalSupply(tokenId) == 0) {
      return false;
    }
    address delegate = DELEGATE.predict(keccak256(abi.encode(claimToken, tokenId)));
    if (depositClaimToken[request.vault] == claimToken) {
      return IERC7540Deposit(request.vault).pendingDepositRequest(request.requestId, delegate) > 0;
    }
    return IERC7540Redeem(request.vault).pendingRedeemRequest(request.requestId, delegate) > 0;
  }

  /// @inheritdoc IERC7540Fungibility
  function redeem(
    address claimToken,
    uint256 tokenId,
    uint256 shares,
    address receiver,
    address owner
  ) external ownerOrOperator(owner) returns (uint256 assets) {
    require(shares > 0, ERC7540FungibilityInvalidInput());
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    Request storage request = requests[claimToken][tokenId];
    require(request.vault != address(0), ERC7540FungibilityTokenNotFound(claimToken, tokenId));

    require(pending(claimToken, tokenId) == false, ERC7540FungibilityPending(claimToken, tokenId));

    address payable delegate = DELEGATE.predict(keccak256(abi.encode(claimToken, tokenId)));

    uint256 balance = ClaimToken(claimToken).balanceOf(owner, tokenId);
    require(shares <= balance, ERC7540FungibilityInsufficientBalance(owner, balance, shares, tokenId));

    ClaimToken(claimToken).burn(owner, tokenId, shares);

    assets = claimToken == depositClaimToken[request.vault]
      ? claimDeposit(delegate, request.vault, shares, receiver)
      : claimRedeem(delegate, request.vault, shares, receiver);

    emit Redeem(claimToken, tokenId, owner, receiver, assets, msg.sender);
  }

  function claimDeposit(
    address payable delegate,
    address vault,
    uint256 shares,
    address receiver
  ) private returns (uint256) {
    bytes memory result = Delegate(delegate).call(
      vault,
      abi.encodeCall(IERC7540Deposit.deposit, (shares, receiver, delegate))
    );

    return abi.decode(result, (uint256));
  }

  function claimRedeem(
    address payable delegate,
    address vault,
    uint256 shares,
    address receiver
  ) private returns (uint256) {
    bytes memory result = Delegate(delegate).call(vault, abi.encodeCall(IERC4626.redeem, (shares, receiver, delegate)));

    return abi.decode(result, (uint256));
  }

  // =========================================================================
  // General
  // =========================================================================

  /// @inheritdoc IERC7540Fungibility
  function setOperator(address spender, bool approved) external returns (bool) {
    require(spender != address(0), ERC7540FungibilityInvalidInput());

    if (isOperator[msg.sender][spender] != approved) {
      isOperator[msg.sender][spender] = approved;
      emit OperatorSet(msg.sender, spender, approved);
    }

    return true;
  }

  function requireInterface(address addr, bytes4 interfaceId) private view {
    require(
      ERC165Checker.supportsInterface(addr, interfaceId),
      ERC7540FungibilityInterfaceNotSupported(addr, interfaceId)
    );
  }
}
