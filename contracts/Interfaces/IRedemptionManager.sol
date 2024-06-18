// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import './IPriceOracle.sol';

interface IRedemptionManager {
  function calcActualRepayAndSeize(
    uint256 redeemAmount,
    address provider,
    address cToken,
    address csuToken
  ) external returns (uint256, uint256, uint256, uint256);

  // function updateSortedBorrows(address csuToken, address borrower) external;

  function getRedemptionRate(address asset) external view returns (uint);

  function getCurrentRedemptionRate(address asset, uint redeemAmount, uint _totalSupply) external returns (uint);

  function redeemFaceValueWithProviderPreview(
    address redeemer,
    address provider,
    address cToken,
    address csuToken,
    uint256 redeemAmount,
    uint256 redemptionRateMantissa
  ) external returns (uint256, uint256, uint256, uint256, uint256, uint256);

  function redeemFaceValue(
    address csuToken,
    uint256 amount,
    address[] memory providers,
    uint256 deadline,
    bytes memory signature
  ) external;
}
