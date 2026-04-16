// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IERC7540Operator {
  /**
   * @dev The event emitted when an operator is set.
   *
   * @param controller The address of the controller.
   * @param operator The address of the operator.
   * @param approved The approval status.
   */
  event OperatorSet(address indexed controller, address indexed operator, bool approved);

  /**
   * @dev Sets or removes an operator for the caller.
   *
   * @param operator The address of the operator.
   * @param approved The approval status.
   * @return Whether the call was executed successfully or not
   */
  function setOperator(address operator, bool approved) external returns (bool);

  /**
   * @dev Returns `true` if the `operator` is approved as an operator for an `controller`.
   *
   * @param controller The address of the controller.
   * @param operator The address of the operator.
   * @return status The approval status
   */
  function isOperator(address controller, address operator) external view returns (bool status);
}
