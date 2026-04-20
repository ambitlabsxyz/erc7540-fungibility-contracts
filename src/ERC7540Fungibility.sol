// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC6909, IERC6909Metadata, IERC6909TokenSupply } from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import { IERC7540Deposit } from "./interfaces/IERC7540Deposit.sol";
import { IERC7540Redeem } from "./interfaces/IERC7540Redeem.sol";
import { IERC8161DepositTransferable } from "./interfaces/IERC8161DepositTransferable.sol";
import { IERC8161RedeemTransferable } from "./interfaces/IERC8161RedeemTransferable.sol";
import { Delegate } from "@ambitlabs/delegate-contracts/Delegate.sol";
import { DelegateLib } from "@ambitlabs/delegate-contracts/DelegateLib.sol";
import { IERC7540Fungibility } from "./interfaces/IERC7540Fungibility.sol";

contract ERC7540Fungibility is ERC165, IERC7540Fungibility {
  using SafeERC20 for IERC20;
  using DelegateLib for address;
  using DelegateLib for Delegate;

  address public immutable DELEGATE;

  enum Kind {
    Deposit,
    Redeem
  }

  struct Token {
    uint256 tokenId;
    address owner;
    address vault;
    Kind kind;
    uint256 requestId;
  }

  uint256 private _tokenId;
  mapping(uint256 id => Token) tokens;

  constructor(address delegate) {
    require(delegate != address(0), ERC7540FungibilityInvalidInput());
    DELEGATE = delegate;
  }

  // =========================================================================
  // Modifiers
  // =========================================================================
  modifier ownerOrOperator(address owner) {
    require(msg.sender == owner || isOperator[owner][msg.sender], ERC7540FungibilityUnauthorized());
    _;
  }

  modifier tokenOwnerOrOperator(uint256 tokenId) {
    require(
      msg.sender == tokens[tokenId].owner || isOperator[tokens[tokenId].owner][msg.sender],
      ERC7540FungibilityUnauthorized()
    );
    _;
  }

  modifier tokenExists(uint256 tokenId) {
    require(tokens[tokenId].tokenId > 0, ERC7540FungibilityTokenNotFound(tokenId));
    _;
  }

  // =========================================================================
  // IERC165
  // =========================================================================

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
    return
      super.supportsInterface(interfaceId) ||
      interfaceId == type(IERC6909).interfaceId ||
      interfaceId == type(IERC6909Metadata).interfaceId ||
      interfaceId == type(IERC6909TokenSupply).interfaceId;
  }

  // =========================================================================
  // IERC6909
  // =========================================================================

  /// @inheritdoc IERC6909
  mapping(address owner => mapping(uint256 id => uint256 balance)) public balanceOf;

  /// @inheritdoc IERC6909
  mapping(address owner => mapping(address spender => mapping(uint256 id => uint256 amount))) public allowance;

  /// @inheritdoc IERC6909
  mapping(address owner => mapping(address operator => bool isOperator)) public isOperator;

  /// @inheritdoc IERC6909
  function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
    require(spender != address(0), ERC6909InvalidSpender(address(0)));

    allowance[msg.sender][spender][id] = amount;

    emit Approval(msg.sender, spender, id, amount);

    return true;
  }

  /// @inheritdoc IERC6909
  function setOperator(address spender, bool approved) external returns (bool) {
    require(spender != address(0), ERC6909InvalidSpender(address(0)));

    if (isOperator[msg.sender][spender] != approved) {
      isOperator[msg.sender][spender] = approved;
      emit OperatorSet(msg.sender, spender, approved);
    }

    return true;
  }

  /// @inheritdoc IERC6909
  function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
    transferShares(msg.sender, receiver, id, amount);
    return true;
  }

  /// @inheritdoc IERC6909
  function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool) {
    if (isOperator[sender][msg.sender] == false) {
      spendAllowance(sender, msg.sender, id, amount);
    }
    transferShares(sender, receiver, id, amount);
    return true;
  }

  function transferShares(address from, address to, uint256 id, uint256 amount) private tokenExists(id) {
    require(from != address(0), ERC6909InvalidSender(address(0)));
    require(to != address(0), ERC6909InvalidReceiver(address(0)));

    uint256 balance = balanceOf[from][id];
    require(amount <= balance, ERC6909InsufficientBalance(from, balance, amount, id));

    unchecked {
      balanceOf[from][id] = balance - amount;
    }
    balanceOf[to][id] += amount;

    emit Transfer(msg.sender, from, to, id, amount);
  }

  function spendAllowance(address owner, address spender, uint256 id, uint256 amount) private {
    uint256 current = allowance[owner][spender][id];

    if (current != type(uint256).max) {
      require(amount <= current, ERC6909InsufficientAllowance(spender, current, amount, id));
      unchecked {
        allowance[owner][spender][id] = current - amount;
      }
    }
  }

  // =========================================================================
  // IERC6909TokenSupply
  // =========================================================================

  /// @inheritdoc IERC6909TokenSupply
  mapping(uint256 id => uint256) public totalSupply;

  // =========================================================================
  // IERC6909Metadata
  // =========================================================================

  /// @inheritdoc IERC6909Metadata
  function name(uint256 id) external view returns (string memory) {}

  /// @inheritdoc IERC6909Metadata
  function symbol(uint256 id) external view returns (string memory) {}

  /// @inheritdoc IERC6909Metadata
  function decimals(uint256 id) external view returns (uint8 dec) {
    if (tokens[id].owner == address(0)) {
      return 0;
    }

    address vault = tokens[id].vault;

    dec = tokens[id].kind == Kind.Redeem
      ? IERC20Metadata(vault).decimals()
      : IERC20Metadata(IERC4626(vault).asset()).decimals();
  }

  // =========================================================================
  // ERC7540Fungibility
  // =========================================================================

  /// @inheritdoc IERC7540Fungibility
  function transferDeposit(
    address vault,
    uint256 requestId,
    address controller,
    address receiver
  ) external ownerOrOperator(controller) returns (uint256 tokenId) {
    requireInterface(vault, type(IERC7540Deposit).interfaceId);
    requireInterface(vault, type(IERC8161DepositTransferable).interfaceId);
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    uint256 assets = IERC7540Deposit(vault).pendingDepositRequest(requestId, controller);
    require(assets > 0, ERC7540FungibilityInvalidInput());

    tokenId = ++_tokenId;

    Token storage token = tokens[tokenId];
    token.tokenId = tokenId;
    token.owner = receiver;
    token.vault = vault;
    token.kind = Kind.Deposit;
    token.requestId = requestId;

    totalSupply[tokenId] = assets;

    balanceOf[token.owner][tokenId] = assets;

    emit Transfer(msg.sender, address(0), token.owner, tokenId, assets);

    address payable delegate = DELEGATE.deploy(tokenId);

    IERC8161DepositTransferable(vault).transferDepositRequest(requestId, controller, delegate);

    emit TransferDeposit(tokenId, vault, token.owner, requestId, msg.sender);
  }

  /// @inheritdoc IERC7540Fungibility
  function transferRedeem(
    address vault,
    uint256 requestId,
    address controller,
    address receiver
  ) external ownerOrOperator(controller) returns (uint256 tokenId) {
    requireInterface(vault, type(IERC7540Redeem).interfaceId);
    requireInterface(vault, type(IERC8161RedeemTransferable).interfaceId);
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    uint256 shares = IERC7540Redeem(vault).pendingRedeemRequest(requestId, controller);
    require(shares > 0, ERC7540FungibilityInvalidInput());

    tokenId = ++_tokenId;

    Token storage token = tokens[tokenId];
    token.tokenId = tokenId;
    token.owner = receiver;
    token.vault = vault;
    token.kind = Kind.Redeem;
    token.requestId = requestId;

    totalSupply[tokenId] = shares;

    balanceOf[token.owner][tokenId] = shares;

    emit Transfer(msg.sender, address(0), token.owner, tokenId, shares);

    address payable delegate = DELEGATE.deploy(tokenId);

    IERC8161RedeemTransferable(vault).transferRedeemRequest(requestId, controller, delegate);

    emit TransferRedeem(tokenId, vault, token.owner, requestId, msg.sender);
  }

  /// @inheritdoc IERC7540Fungibility
  function requestDeposit(
    address vault,
    uint256 assets,
    address owner,
    address receiver
  ) external ownerOrOperator(owner) returns (uint256 tokenId) {
    requireInterface(vault, type(IERC7540Deposit).interfaceId);
    require(assets > 0, ERC7540FungibilityInvalidInput());
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    tokenId = ++_tokenId;

    Token storage token = tokens[tokenId];
    token.tokenId = tokenId;
    token.owner = receiver;
    token.vault = vault;
    token.kind = Kind.Deposit;

    totalSupply[tokenId] = assets;

    balanceOf[token.owner][tokenId] = assets;

    emit Transfer(msg.sender, address(0), token.owner, tokenId, assets);

    token.requestId = requestDeposit(vault, assets, owner, tokenId);

    emit RequestDeposit(tokenId, vault, token.owner, assets, msg.sender);
  }

  function requestDeposit(
    address vault,
    uint256 assets,
    address owner,
    uint256 tokenId
  ) private returns (uint256 requestId) {
    address payable delegate = DELEGATE.deploy(tokenId);

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
  ) external ownerOrOperator(owner) returns (uint256 tokenId) {
    requireInterface(vault, type(IERC7540Redeem).interfaceId);
    require(shares > 0, ERC7540FungibilityInvalidInput());
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    tokenId = ++_tokenId;

    Token storage token = tokens[tokenId];
    token.tokenId = tokenId;
    token.owner = receiver;
    token.vault = vault;
    token.kind = Kind.Redeem;

    totalSupply[tokenId] = shares;

    balanceOf[token.owner][tokenId] = shares;

    emit Transfer(msg.sender, address(0), token.owner, tokenId, shares);

    token.requestId = requestRedeem(vault, shares, owner, tokenId);

    emit RequestRedeem(tokenId, vault, token.owner, shares, msg.sender);
  }

  function requestRedeem(
    address vault,
    uint256 shares,
    address owner,
    uint256 tokenId
  ) private returns (uint256 requestId) {
    address payable delegate = DELEGATE.deploy(tokenId);

    IERC20(vault).safeTransferFrom(owner, delegate, shares);

    Delegate(delegate).safeApprove(address(vault), vault, shares);

    bytes memory result = Delegate(delegate).call(
      vault,
      abi.encodeCall(IERC7540Redeem.requestRedeem, (shares, delegate, delegate))
    );

    requestId = abi.decode(result, (uint256));
  }

  /// @inheritdoc IERC7540Fungibility
  function cancel(uint256 tokenId, address controller) external tokenExists(tokenId) tokenOwnerOrOperator(tokenId) {
    require(controller != address(0), ERC7540FungibilityInvalidInput());

    Token storage token = tokens[tokenId];

    // can only cancel if the owner still holds all of the supply and the request is still pending
    uint256 balance = balanceOf[token.owner][tokenId];
    require(balance == totalSupply[tokenId] && pending(tokenId), ERC7540FungibilityCancelNotAllowed(tokenId));

    balanceOf[token.owner][tokenId] = 0;
    totalSupply[tokenId] = 0;

    emit Transfer(msg.sender, token.owner, address(0), tokenId, balance);

    address payable delegate = DELEGATE.predict(tokenId);

    if (token.kind == Kind.Deposit) {
      requireInterface(token.vault, type(IERC8161DepositTransferable).interfaceId);
      Delegate(delegate).call(
        token.vault,
        abi.encodeCall(IERC8161DepositTransferable.transferDepositRequest, (token.requestId, delegate, controller))
      );
    } else {
      requireInterface(token.vault, type(IERC8161RedeemTransferable).interfaceId);
      Delegate(delegate).call(
        token.vault,
        abi.encodeCall(IERC8161RedeemTransferable.transferRedeemRequest, (token.requestId, delegate, controller))
      );
    }

    emit Cancel(tokenId, controller, msg.sender);
  }

  function pending(uint256 tokenId) public view returns (bool) {
    Token storage token = tokens[tokenId];
    return totalSupply[tokenId] > 0 && (token.kind == Kind.Deposit ? pendingDeposit(token) : pendingRedeem(token));
  }

  function pendingDeposit(Token storage token) private view returns (bool) {
    address delegate = DELEGATE.predict(token.tokenId);
    return IERC7540Deposit(token.vault).pendingDepositRequest(token.requestId, delegate) > 0;
  }

  function pendingRedeem(Token storage token) private view returns (bool) {
    address delegate = DELEGATE.predict(token.tokenId);
    return IERC7540Redeem(token.vault).pendingRedeemRequest(token.requestId, delegate) > 0;
  }

  /// @inheritdoc IERC7540Fungibility
  function redeem(
    uint256 tokenId,
    uint256 shares,
    address receiver,
    address owner
  ) external ownerOrOperator(owner) tokenExists(tokenId) returns (uint256 assets) {
    require(shares > 0, ERC7540FungibilityInvalidInput());
    require(receiver != address(0), ERC7540FungibilityInvalidInput());

    require(pending(tokenId) == false, ERC7540FungibilityPending(tokenId));

    Token storage token = tokens[tokenId];

    uint256 balance = balanceOf[owner][tokenId];
    require(shares <= balance, ERC6909InsufficientBalance(owner, balance, shares, tokenId));

    balanceOf[owner][tokenId] -= shares;
    totalSupply[tokenId] -= shares;

    emit Transfer(msg.sender, owner, address(0), tokenId, shares);

    assets = claim(token, shares, receiver);

    emit Redeem(tokenId, owner, receiver, assets, msg.sender);
  }

  function claim(Token storage token, uint256 shares, address receiver) private returns (uint256) {
    return token.kind == Kind.Deposit ? claimDeposit(token, shares, receiver) : claimRedeem(token, shares, receiver);
  }

  function claimDeposit(Token storage token, uint256 shares, address receiver) private returns (uint256) {
    address payable delegate = DELEGATE.predict(token.tokenId);

    bytes memory result = Delegate(delegate).call(
      token.vault,
      abi.encodeCall(IERC7540Deposit.deposit, (shares, receiver, delegate))
    );

    return abi.decode(result, (uint256));
  }

  function claimRedeem(Token storage token, uint256 shares, address receiver) private returns (uint256) {
    address payable delegate = DELEGATE.predict(token.tokenId);

    bytes memory result = Delegate(delegate).call(
      token.vault,
      abi.encodeCall(IERC4626.redeem, (shares, receiver, delegate))
    );

    return abi.decode(result, (uint256));
  }

  // =========================================================================
  // General
  // =========================================================================

  function requireInterface(address addr, bytes4 interfaceId) private view {
    require(
      ERC165Checker.supportsInterface(addr, interfaceId),
      ERC7540FungibilityInterfaceNotSupported(addr, interfaceId)
    );
  }
}
