// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ICToken {
  function comptroller() external view returns (address);

  function reserveFactorMantissa() external view returns (uint256);

  function borrowIndex() external view returns (uint256);

  function totalBorrows() external view returns (uint256);

  function totalSupply() external view returns (uint256);

  function isCToken() external view returns (bool);

  function balanceOf(address owner) external view returns (uint256);

  function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256);

  function borrowBalanceStored(address account) external view returns (uint256);

  function exchangeRateStored() external view returns (uint256);

  function underlying() external view returns (address);

  function exchangeRateCurrent() external returns (uint256);

  function isCEther() external view returns (bool);

  function supplyRatePerBlock() external view returns (uint256);

  function borrowRatePerBlock() external view returns (uint256);

  function totalReserves() external view returns (uint256);

  function getCash() external view returns (uint256);

  function decimals() external view returns (uint8);

  function borrowBalanceCurrent(address account) external returns (uint256);

  function balanceOfUnderlying(address owner) external returns (uint256);

  function allowance(address owner, address spender) external view returns (uint256);

  function getCurrentVotes(address account) external view returns (uint96);

  function delegates(address) external view returns (address);

  function getPriorVotes(address account, uint256 blockNumber) external view returns (uint96);

  function executeRedemption(
    address redeemer,
    address provider,
    uint256 repayAmount,
    address cTokenCollateral,
    uint256 seizeAmount,
    uint256 redemptionRateMantissa
  ) external;

  function discountRateMantissa() external view returns (uint256);

  function accrueInterest() external;

  function liquidateCalculateSeizeTokens(
    address cTokenCollateral,
    uint256 actualRepayAmount
  ) external view returns (uint256, uint256);

  function protocolSeizeShareMantissa() external view returns (uint256);
}
