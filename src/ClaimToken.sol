// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ERC6909TokenSupply } from "@openzeppelin/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";
import { IERC6909Metadata } from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract ClaimToken is ERC6909TokenSupply, IERC6909Metadata {
  using Strings for uint256;

  uint256 private _tokenId;

  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual override(ERC6909TokenSupply, IERC165) returns (bool) {
    return interfaceId == type(IERC6909Metadata).interfaceId || super.supportsInterface(interfaceId);
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

  function name(uint256 id) external view returns (string memory) {
    (, , uint8 kind) = args();
    return string.concat(kind == 0 ? "ERC7540 Deposit Claim" : "ERC7540 Redeem Claim", " #", id.toString());
  }

  function symbol(uint256 id) external view returns (string memory) {
    (, , uint8 kind) = args();
    return string.concat(kind == 0 ? "ERC7540DCLAIM" : "ERC7540RCLAIM", " #", id.toString());
  }

  function decimals(uint256) external view returns (uint8) {
    (, address v, uint8 k) = args();

    // for deposit tokens, claim represents assets; for redeem tokens, shares.
    return k == 0 ? IERC20Metadata(IERC4626(v).asset()).decimals() : IERC20Metadata(v).decimals();
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
