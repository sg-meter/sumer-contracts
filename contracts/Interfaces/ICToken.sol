// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ICToken {
  /*** User Interface ***/

  function transfer(address dst, uint256 amount) external returns (bool);

  function transferFrom(address src, address dst, uint256 amount) external returns (bool);

  function approve(address spender, uint256 amount) external returns (bool);

  function allowance(address owner, address spender) external view returns (uint256);

  function balanceOf(address owner) external view returns (uint256);

  function totalSupply() external view returns (uint256);

  function balanceOfUnderlying(address owner) external returns (uint256);

  function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256);

  function borrowRatePerBlock() external view returns (uint256);

  function supplyRatePerBlock() external view returns (uint256);

  function totalBorrowsCurrent() external returns (uint256);

  function borrowBalanceCurrent(address account) external returns (uint256);

  function borrowBalanceStored(address account) external view returns (uint256);

  function exchangeRateCurrent() external returns (uint256);

  function exchangeRateStored() external view returns (uint256);

  function getCash() external view returns (uint256);

  function accrueInterest() external returns (uint256);

  // function accrualBlockNumber() external returns (uint256);

  function seize(
    address liquidator,
    address borrower,
    uint256 seizeTokens,
    uint256 seizeProfitTokens,
    bool isRedemption,
    uint256 redemptionRateMantissa
  ) external returns (uint256);

  /*** Admin Functions ***/

  function _setPendingAdmin(address payable newPendingAdmin) external returns (uint256);

  function _acceptAdmin() external returns (uint256);

  function _setComptroller(address newComptroller) external returns (uint256);

  function _setReserveFactor(uint256 newReserveFactorMantissa) external returns (uint256);

  function _reduceReserves(uint256 reduceAmount) external returns (uint256);

  function _setInterestRateModel(address newInterestRateModel) external returns (uint256);

  function _setDiscountRate(uint256 discountRateMantissa) external returns (uint256);

  function accrualBlockTimestamp() external returns (uint256);
}
