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
import { IERC7575 } from "./interfaces/IERC7575.sol";
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

  struct Request {
    address vault;
    uint256 requestId;
  }

  mapping(address claimToken => mapping(uint256 tokenId => Request)) public requests;

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

  /// @inheritdoc IERC7540Fungibility
  function depositClaimToken(address vault) public view returns (address claimToken) {
    claimToken = Clones.predictDeterministicAddressWithImmutableArgs(
      CLAIM_TOKEN,
      abi.encode(address(this), vault, 0),
      0,
      address(this)
    );
  }

  /// @inheritdoc IERC7540Fungibility
  function redeemClaimToken(address vault) public view returns (address claimToken) {
    claimToken = Clones.predictDeterministicAddressWithImmutableArgs(
      CLAIM_TOKEN,
      abi.encode(address(this), vault, 1),
      0,
      address(this)
    );
  }

  /// @inheritdoc IERC7540Fungibility
  function initializeDepositClaimToken(address vault) public returns (address claimToken) {
    claimToken = depositClaimToken(vault);
    if (claimToken.code.length == 0) {
      claimToken = Clones.cloneDeterministicWithImmutableArgs(CLAIM_TOKEN, abi.encode(address(this), vault, 0), 0);
    }
  }

  /// @inheritdoc IERC7540Fungibility
  function initializeRedeemClaimToken(address vault) public returns (address claimToken) {
    claimToken = redeemClaimToken(vault);
    if (claimToken.code.length == 0) {
      claimToken = Clones.cloneDeterministicWithImmutableArgs(CLAIM_TOKEN, abi.encode(address(this), vault, 1), 0);
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

    claimToken = initializeDepositClaimToken(vault);

    tokenId = ClaimToken(claimToken).next();

    Request storage request = requests[claimToken][tokenId];
    request.vault = vault;
    request.requestId = requestId;

    ClaimToken(claimToken).mint(receiver, tokenId, assets);

    address payable delegate = DELEGATE.deploy(delegateSalt(claimToken, tokenId));

    IERC8161DepositTransferable(vault).transferDepositRequest(requestId, controller, delegate);

    emit TransferDeposit(claimToken, tokenId, vault, receiver, requestId, msg.sender);
  }

  /// @inheritdoc IERC7540Fungibility
  function pendingDepositRequest(address claimToken, uint256 tokenId) external view returns (uint256 assets) {
    Request storage request = requests[claimToken][tokenId];
    requireInterface(request.vault, type(IERC7540Deposit).interfaceId);

    assets = IERC7540Deposit(request.vault).pendingDepositRequest(request.requestId, delegateOf(claimToken, tokenId));
  }

  /// @inheritdoc IERC7540Fungibility
  function claimableDepositRequest(address claimToken, uint256 tokenId) external view returns (uint256 assets) {
    Request storage request = requests[claimToken][tokenId];
    requireInterface(request.vault, type(IERC7540Deposit).interfaceId);

    assets = IERC7540Deposit(request.vault).claimableDepositRequest(request.requestId, delegateOf(claimToken, tokenId));
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

    claimToken = initializeRedeemClaimToken(vault);

    tokenId = ClaimToken(claimToken).next();

    Request storage request = requests[claimToken][tokenId];
    request.vault = vault;
    request.requestId = requestId;

    ClaimToken(claimToken).mint(receiver, tokenId, shares);

    address payable delegate = DELEGATE.deploy(delegateSalt(claimToken, tokenId));

    IERC8161RedeemTransferable(vault).transferRedeemRequest(requestId, controller, delegate);

    emit TransferRedeem(claimToken, tokenId, vault, receiver, requestId, msg.sender);
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

    claimToken = initializeDepositClaimToken(vault);

    tokenId = ClaimToken(claimToken).next();

    address payable delegate = DELEGATE.deploy(delegateSalt(claimToken, tokenId));

    // Interactions first: pull assets and open the vault request
    uint256 requestId = requestDeposit(delegate, vault, assets, owner);

    // Effects last: only now record the request and mint the claim tokens
    Request storage request = requests[claimToken][tokenId];
    request.vault = vault;
    request.requestId = requestId;

    ClaimToken(claimToken).mint(receiver, tokenId, assets);

    emit RequestDeposit(claimToken, tokenId, vault, receiver, assets, msg.sender);
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

    claimToken = initializeRedeemClaimToken(vault);

    tokenId = ClaimToken(claimToken).next();

    address payable delegate = DELEGATE.deploy(delegateSalt(claimToken, tokenId));

    // Interactions first: pull assets and open the vault request
    uint256 requestId = requestRedeem(delegate, vault, shares, owner);

    // Effects last: only now record the request and mint the claim tokens
    Request storage request = requests[claimToken][tokenId];
    request.vault = vault;
    request.requestId = requestId;

    ClaimToken(claimToken).mint(receiver, tokenId, shares);

    emit RequestRedeem(claimToken, tokenId, vault, receiver, shares, msg.sender);
  }

  function requestRedeem(
    address payable delegate,
    address vault,
    uint256 shares,
    address owner
  ) private returns (uint256 requestId) {
    // the vault could be IERC7575 which has an external share token so we support that
    address shareToken = ERC165Checker.supportsInterface(vault, type(IERC7575).interfaceId) == false
      ? vault
      : IERC7575(vault).share();

    IERC20(shareToken).safeTransferFrom(owner, delegate, shares);

    Delegate(delegate).safeApprove(shareToken, vault, shares);

    bytes memory result = Delegate(delegate).call(
      vault,
      abi.encodeCall(IERC7540Redeem.requestRedeem, (shares, delegate, delegate))
    );

    requestId = abi.decode(result, (uint256));
  }

  /// @inheritdoc IERC7540Fungibility
  function pendingRedeemRequest(address claimToken, uint256 tokenId) external view returns (uint256 shares) {
    Request storage request = requests[claimToken][tokenId];
    requireInterface(request.vault, type(IERC7540Redeem).interfaceId);

    shares = IERC7540Redeem(request.vault).pendingRedeemRequest(request.requestId, delegateOf(claimToken, tokenId));
  }

  /// @inheritdoc IERC7540Fungibility
  function claimableRedeemRequest(address claimToken, uint256 tokenId) external view returns (uint256 shares) {
    Request storage request = requests[claimToken][tokenId];
    requireInterface(request.vault, type(IERC7540Redeem).interfaceId);

    shares = IERC7540Redeem(request.vault).claimableRedeemRequest(request.requestId, delegateOf(claimToken, tokenId));
  }

  /// @inheritdoc IERC7540Fungibility
  function cancel(
    address claimToken,
    uint256 tokenId,
    address owner,
    address controller
  ) external ownerOrOperator(owner) {
    require(controller != address(0), ERC7540FungibilityInvalidInput());

    Request memory request = requests[claimToken][tokenId];
    require(request.vault != address(0), ERC7540FungibilityTokenNotFound(claimToken, tokenId));

    uint256 totalSupply = ClaimToken(claimToken).totalSupply(tokenId);
    require(totalSupply > 0, ERC7540FungibilityCancelNotAllowed(claimToken, tokenId));

    // can only cancel if the owner still holds all of the supply
    uint256 balance = ClaimToken(claimToken).balanceOf(owner, tokenId);
    require(balance == totalSupply, ERC7540FungibilityCancelNotAllowed(claimToken, tokenId));

    emit Cancel(claimToken, tokenId, owner, controller, msg.sender);

    delete requests[claimToken][tokenId];

    ClaimToken(claimToken).burn(owner, tokenId, balance);

    address payable delegate = payable(delegateOf(claimToken, tokenId));

    if (depositClaimToken(request.vault) == claimToken) {
      requireInterface(request.vault, type(IERC8161DepositTransferable).interfaceId);

      // nothing is waiting to be claimed
      uint256 claimable = IERC7540Deposit(request.vault).claimableDepositRequest(request.requestId, delegate);
      require(claimable == 0, ERC7540FungibilityCancelNotAllowed(claimToken, tokenId));

      Delegate(delegate).call(
        request.vault,
        abi.encodeCall(IERC8161DepositTransferable.transferDepositRequest, (request.requestId, delegate, controller))
      );
    } else {
      requireInterface(request.vault, type(IERC8161RedeemTransferable).interfaceId);

      // nothing is waiting to be claimed
      uint256 claimable = IERC7540Redeem(request.vault).claimableRedeemRequest(request.requestId, delegate);
      require(claimable == 0, ERC7540FungibilityCancelNotAllowed(claimToken, tokenId));

      Delegate(delegate).call(
        request.vault,
        abi.encodeCall(IERC8161RedeemTransferable.transferRedeemRequest, (request.requestId, delegate, controller))
      );
    }
  }

  function claim(
    address claimToken,
    uint256 tokenId,
    uint256 shares,
    address receiver,
    address owner
  ) private returns (address vault) {
    require(shares > 0, ERC7540FungibilityInvalidInput());
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    Request storage request = requests[claimToken][tokenId];

    vault = request.vault;
    require(vault != address(0), ERC7540FungibilityTokenNotFound(claimToken, tokenId));

    uint256 balance = ClaimToken(claimToken).balanceOf(owner, tokenId);
    require(shares <= balance, ERC7540FungibilityInsufficientBalance(owner, balance, shares, tokenId));

    ClaimToken(claimToken).burn(owner, tokenId, shares);

    if (ClaimToken(claimToken).totalSupply(tokenId) == 0) {
      delete requests[claimToken][tokenId];
    }
  }

  /// @inheritdoc IERC7540Fungibility
  function redeem(
    address claimToken,
    uint256 tokenId,
    uint256 shares,
    address receiver,
    address owner
  ) external ownerOrOperator(owner) returns (uint256 assets) {
    address vault = claim(claimToken, tokenId, shares, receiver, owner);

    require(claimToken == redeemClaimToken(vault), ERC7540FungibilityInvalidInput());

    address payable delegate = payable(delegateOf(claimToken, tokenId));

    bytes memory result = Delegate(delegate).call(vault, abi.encodeCall(IERC4626.redeem, (shares, receiver, delegate)));
    assets = abi.decode(result, (uint256));

    emit Redeem(claimToken, tokenId, owner, receiver, shares, assets, msg.sender);
  }

  /// @inheritdoc IERC7540Fungibility
  function deposit(
    address claimToken,
    uint256 tokenId,
    uint256 assets,
    address receiver,
    address owner
  ) external ownerOrOperator(owner) returns (uint256 shares) {
    address vault = claim(claimToken, tokenId, assets, receiver, owner);

    require(claimToken == depositClaimToken(vault), ERC7540FungibilityInvalidInput());

    address payable delegate = payable(delegateOf(claimToken, tokenId));

    bytes memory result = Delegate(delegate).call(
      vault,
      abi.encodeCall(IERC7540Deposit.deposit, (assets, receiver, delegate))
    );
    shares = abi.decode(result, (uint256));

    emit Deposit(claimToken, tokenId, owner, receiver, shares, assets, msg.sender);
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

  /// @inheritdoc IERC7540Fungibility
  function delegateOf(address claimToken, uint256 tokenId) public view returns (address delegate) {
    delegate = DELEGATE.predict(delegateSalt(claimToken, tokenId), address(this));
  }

  function delegateSalt(address claimToken, uint256 tokenId) private pure returns (bytes32) {
    return keccak256(abi.encode(claimToken, tokenId));
  }
}
