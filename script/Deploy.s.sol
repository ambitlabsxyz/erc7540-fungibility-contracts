// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { ClaimToken } from "../src/ClaimToken.sol";
import { ERC7540Fungibility } from "../src/ERC7540Fungibility.sol";

// 0x8eb34766a14952cC39223E3066f4B2bb5dE9D769

interface ICreateX {
  function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
}

contract Deploy is Script {
  ICreateX public CreateX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

  // forge script .\script\Deploy.s.sol:Deploy --sig deployClaimToken() --rpc-url plume --broadcast --account hd-qa --skip-simulation
  function deployClaimToken() external {
    vm.startBroadcast();

    // deploy the claim token
    bytes32 salt = keccak256("erc7540-fungibility-contracts.claim-token.v1");

    bytes memory initCode = abi.encodePacked(type(ClaimToken).creationCode);

    address claimToken = CreateX.deployCreate3(salt, initCode);

    console.log("Claim token deployed to:", claimToken);

    vm.stopBroadcast();
  }

  // forge script .\script\Deploy.s.sol:Deploy --sig deploy() --rpc-url plume --broadcast --account hd-qa --skip-simulation
  function deploy() external {
    vm.startBroadcast();

    ICreateX createX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    // deploy the claim token
    bytes32 salt = keccak256("erc7540-fungibility-contracts.v1");

    bytes memory initCode = bytes.concat(
      type(ERC7540Fungibility).creationCode,
      abi.encode(0x3fBc32E2b50300e1b72f2206d1f23666bDF2176C, 0x0)
    );

    address fungibility = createX.deployCreate3(salt, initCode);

    console.log("ERC7540Fungibility deployed to:", fungibility);

    vm.stopBroadcast();
  }

  // // forge script .\script\Deploy.s.sol:Deploy --rpc-url hyperevm --broadcast --account hd-qa --skip-simulation
  // function run() external {
  //   vm.startBroadcast();

  //   ClaimToken claimToken = new ClaimToken();

  //   ERC7540Fungibility fungibility = new ERC7540Fungibility(
  //     0x3fBc32E2b50300e1b72f2206d1f23666bDF2176C,
  //     address(claimToken)
  //   );

  //   console.log("ERC7540Fungibility deployed to:", address(fungibility));

  //   vm.stopBroadcast();
  // }
}
