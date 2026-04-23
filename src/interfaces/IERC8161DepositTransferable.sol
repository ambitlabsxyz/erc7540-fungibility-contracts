// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IERC7540DepositTransferable
 *
 * @notice Extension of ERC-7540 enabling transferability of pending deposit
 *         requests. ERC-165 interface ID: 0x53b3bb0a
 */
interface IERC8161DepositTransferable {
  event TransferDepositRequest(uint256 indexed requestId, address indexed from, address indexed to, address sender);

  /**
   * @notice Transfers the entire pending deposit request balance from
   *         oldController to newController for the given requestId.
   *
   * @dev MUST only transfer the Pending balance. Claimable balances
   *      MUST NOT be affected.
   *
   *      msg.sender MUST be oldController or an operator approved by
   *      oldController.
   */
  function transferDepositRequest(uint256 requestId, address oldController, address newController) external;
}
