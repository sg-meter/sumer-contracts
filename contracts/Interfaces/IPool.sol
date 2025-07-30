// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPool {
  function getVault() external view returns (address);
  function getPoolId() external view returns (bytes32);
  function totalSupply() external view returns (uint256);
  function decimals() external view returns (uint8);
  function getActualSupply() external view returns (uint256);
  function getNormalizedWeights() external view returns (uint256[] memory);
  function getInvariant() external view returns (uint256);
  function getTokenRate(address token) external view returns (uint256);
  function getRate() external view returns (uint256);
}
