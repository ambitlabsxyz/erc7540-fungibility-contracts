// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { ClaimToken } from "../src/ClaimToken.sol";
import { ERC7540Fungibility } from "../src/ERC7540Fungibility.sol";

// 0x8eb34766a14952cC39223E3066f4B2bb5dE9D769

contract Deploy is Script {
  // forge script .\script\Deploy.s.sol:Deploy --rpc-url hyperevm --broadcast --account hd-qa --skip-simulation
  function run() external {
    vm.startBroadcast();

    ClaimToken claimToken = new ClaimToken();

    ERC7540Fungibility fungibility = new ERC7540Fungibility(
      0x3fBc32E2b50300e1b72f2206d1f23666bDF2176C,
      address(claimToken)
    );

    console.log("ERC7540Fungibility deployed to:", address(fungibility));

    vm.stopBroadcast();
  }
}
