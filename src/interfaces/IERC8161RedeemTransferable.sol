// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IERC7540RedeemTransferable
 *
 * @notice Extension of ERC-7540 enabling transferability of pending redeem
 *         requests. ERC-165 interface ID: 0x7846f5bd
 */
interface IERC8161RedeemTransferable {
  event TransferRedeemRequest(uint256 indexed requestId, address indexed from, address indexed to, uint256 shares);

  /**
   * @notice Transfers the entire pending redeem request balance from
   *         oldController to newController for the given requestId.
   *
   * @dev MUST only transfer the Pending balance. Claimable balances
   *      MUST NOT be affected.
   *
   *      msg.sender MUST be oldController or an operator approved by
   *      oldController.
   */
  function transferRedeemRequest(uint256 requestId, address oldController, address newController) external;
}
