//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.19;

import '@openzeppelin/contracts/governance/TimelockController.sol';

contract SumerTimelockController is TimelockController {
  constructor(
    uint256 minDelay,
    address[] memory proposers,
    address[] memory executors
  ) TimelockController(minDelay, proposers, executors, msg.sender) {}
}
