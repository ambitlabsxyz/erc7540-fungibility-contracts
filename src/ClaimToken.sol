// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC6909TokenSupply } from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import { ERC6909TokenSupply } from "@openzeppelin/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";
import { IERC6909Metadata } from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MetadataReaderLib } from "solady/utils/MetadataReaderLib.sol";
import { IERC7575 } from "./interfaces/IERC7575.sol";

contract ClaimToken is ERC6909TokenSupply, IERC6909Metadata {
  using Strings for uint256;

  uint256 private _tokenId;

  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual override(ERC6909TokenSupply, IERC165) returns (bool supported) {
    supported =
      interfaceId == type(IERC6909Metadata).interfaceId ||
      interfaceId == type(IERC6909TokenSupply).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  function args() private view returns (address, address, uint8) {
    return abi.decode(Clones.fetchCloneArgs(address(this)), (address, address, uint8));
  }

  function owner() public view returns (address owner_) {
    (owner_, , ) = args();
  }

  function vault() public view returns (address vault_) {
    (, vault_, ) = args();
  }

  function share() public view returns (address share_) {
    (, address vault_, ) = args();

    share_ = ERC165Checker.supportsInterface(vault_, type(IERC7575).interfaceId) == false
      ? vault_
      : IERC7575(vault_).share();
  }

  function name(uint256 id) external view returns (string memory) {
    (, , uint8 kind) = args();

    string memory name_ = MetadataReaderLib.readName(share());

    if (bytes(name_).length == 0) {
      name_ = "ERC7540";
    }

    return string.concat(name_, kind == 0 ? " (Deposit Claim #" : " (Redeem Claim #", id.toString(), ")");
  }

  function symbol(uint256 id) external view returns (string memory) {
    string memory symbol_ = MetadataReaderLib.readSymbol(share());

    if (bytes(symbol_).length == 0) {
      symbol_ = "CLAIM";
    }

    return string.concat(symbol_, "-", id.toString());
  }

  function decimals(uint256) external view returns (uint8) {
    (, address vault_, uint8 kind_) = args();

    if (kind_ == 0) {
      // for deposit tokens, claim represents assets
      return MetadataReaderLib.readDecimals(IERC4626(vault_).asset());
    }

    // for redeem tokens, claim represents shares.
    return MetadataReaderLib.readDecimals(share());
  }

  function current() external view returns (uint256) {
    return _tokenId;
  }

  function next() external returns (uint256 tokenId) {
    require(msg.sender == owner());
    tokenId = ++_tokenId;
  }

  function mint(address to, uint256 id, uint256 amount) external {
    require(msg.sender == owner());
    _mint(to, id, amount);
  }

  function burn(address from, uint256 id, uint256 amount) external {
    require(msg.sender == owner());
    _burn(from, id, amount);
  }
}
