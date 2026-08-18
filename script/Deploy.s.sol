// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { ClaimToken } from "../src/ClaimToken.sol";
import { ERC7540Fungibility } from "../src/ERC7540Fungibility.sol";
import { IERC7575 } from "../src/interfaces/IERC7575.sol";

address constant DEPLOYER = 0x6B887caC2e0Ef29306E1B6F22E716796105137a0;

// erc7540-fungibility-contracts.claim-token.v1 = 0xE85F90fBD15ac40896ec0cBcC8C0E3CfafED64E5;
// erc7540-fungibility-contracts.claim-token.v2 = 0x492b0b1f996824F3B39f31Fc254C8B04abe0EB24;
// erc7540-fungibility-contracts.v1 = 0x8D383f607A6CE09462d6413EE430D42D758F551B
// erc7540-fungibility-contracts.v2 = 0xF932B6378b1429afa8a83F6Ec18D1BB4b2d08786
// erc7540-fungibility-contracts.v3 = 0x46262389Ff023fA481E5Df9426A2793Fc8A3d2Fa
// erc7540-fungibility-contracts.v4 = 0x3519C244B59d18de8D2a468C8c5ad5d422A9eB4E

interface ICreateX {
  function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

  function computeCreate3Address(bytes32 salt) external view returns (address computedAddress);

  function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address computedAddress);
}

contract Deploy is Script {
  ICreateX public CreateX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

  // forge script .\script\Deploy.s.sol:Deploy --sig deployClaimToken --rpc-url plume --broadcast --account deployer --skip-simulation
  function deployClaimToken() external {
    vm.startBroadcast();

    // deploy the claim token
    bytes32 salt = bytes32(
      abi.encodePacked(DEPLOYER, hex"00", bytes11(keccak256("erc7540-fungibility-contracts.claim-token.v2")))
    );

    bytes memory initCode = abi.encodePacked(type(ClaimToken).creationCode);

    address claimToken = CreateX.deployCreate3(salt, initCode);

    console.log("Claim token deployed to:", claimToken);

    vm.stopBroadcast();
  }

  // forge script .\script\Deploy.s.sol:Deploy --sig deploy --rpc-url plume --broadcast --account deployer --skip-simulation
  // forge script .\script\Deploy.s.sol:Deploy --sig deploy --rpc-url hyperevm --broadcast --account deployer --skip-simulation
  function deploy() external {
    vm.startBroadcast();

    ICreateX createX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    // deploy the claim token
    bytes32 salt = bytes32(abi.encodePacked(DEPLOYER, hex"00", bytes11(keccak256("erc7540-fungibility-contracts.v4"))));

    bytes memory initCode = bytes.concat(
      type(ERC7540Fungibility).creationCode,
      abi.encode(0xF1c8F785542E398F52A63f9B27984ce57fF03942, 0x492b0b1f996824F3B39f31Fc254C8B04abe0EB24)
    );

    address fungibility = createX.deployCreate3(salt, initCode);

    console.log("ERC7540Fungibility deployed to:", fungibility);

    vm.stopBroadcast();
  }
}
