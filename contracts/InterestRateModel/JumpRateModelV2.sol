// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import './InterestRateModel.sol';

/**
 * @title Compound's JumpRateModel Contract V2 for V2 cTokens
 * @author Arr00
 * @notice Supports only for V2 cTokens
 */
contract JumpRateModelV2 is InterestRateModel {
  using SafeMath for uint256;

  event NewInterestParams(
    uint256 baseRatePerSecond,
    uint256 multiplierPerSecond,
    uint256 jumpMultiplierPerSecond,
    uint256 kink
  );

  /**
   * @notice The multiplier of utilization rate that gives the slope of the interest rate
   */
  uint256 public multiplierPerSecond;

  /**
   * @notice The base interest rate which is the y-intercept when utilization rate is 0
   */
  uint256 public baseRatePerSecond;

  /**
   * @notice The multiplierPerSecond after hitting a specified utilization point
   */
  uint256 public jumpMultiplierPerSecond;

  /**
   * @notice The utilization point at which the jump multiplier is applied
   */
  uint256 public kink;

  /**
   * @notice Construct an interest rate model
   * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
   * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
   * @param jumpMultiplierPerYear The multiplierPerSecond after hitting a specified utilization point
   * @param kink_ The utilization point at which the jump multiplier is applied
   */
  constructor(uint256 baseRatePerYear, uint256 multiplierPerYear, uint256 jumpMultiplierPerYear, uint256 kink_) {
    _updateJumpRateModelInternal(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, kink_);
  }

  /**
   * @notice Update the parameters of the interest rate model (only callable by owner, i.e. Timelock)
   * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
   * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
   * @param jumpMultiplierPerYear The multiplierPerSecond after hitting a specified utilization point
   * @param kink_ The utilization point at which the jump multiplier is applied
   */
  function updateJumpRateModel(
    uint256 baseRatePerYear,
    uint256 multiplierPerYear,
    uint256 jumpMultiplierPerYear,
    uint256 kink_
  ) external virtual onlyOwner {
    _updateJumpRateModelInternal(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, kink_);
  }

  /**
   * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`
   * @param cash The amount of cash in the market
   * @param borrows The amount of borrows in the market
   * @param reserves The amount of reserves in the market (currently unused)
   * @return The utilization rate as a mantissa between [0, 1e18]
   */
  function utilizationRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
    // Utilization rate is 0 when there are no borrows
    if (borrows == 0) {
      return 0;
    }
    if (reserves > cash && (borrows + cash - reserves > 0)) {
      return 1e18;
    }

    return borrows.mul(1e18).div(cash.add(borrows).sub(reserves));
  }

  /**
   * @notice Calculates the current borrow rate per block, with the error code expected by the market
   * @param cash The amount of cash in the market
   * @param borrows The amount of borrows in the market
   * @param reserves The amount of reserves in the market
   * @return The borrow rate percentage per block as a mantissa (scaled by 1e18)
   */
  function getBorrowRateInternal(uint256 cash, uint256 borrows, uint256 reserves) internal view returns (uint256) {
    uint256 util = utilizationRate(cash, borrows, reserves);

    if (util <= kink) {
      return util.mul(multiplierPerSecond).div(1e18).add(baseRatePerSecond);
    } else {
      uint256 normalRate = kink.mul(multiplierPerSecond).div(1e18).add(baseRatePerSecond);
      uint256 excessUtil = util.sub(kink);
      return excessUtil.mul(jumpMultiplierPerSecond).div(1e18).add(normalRate);
    }
  }

  /**
   * @notice Calculates the current supply rate per block
   * @param cash The amount of cash in the market
   * @param borrows The amount of borrows in the market
   * @param reserves The amount of reserves in the market
   * @param reserveFactorMantissa The current reserve factor for the market
   * @return The supply rate percentage per block as a mantissa (scaled by 1e18)
   */
  function getSupplyRate(
    uint256 cash,
    uint256 borrows,
    uint256 reserves,
    uint256 reserveFactorMantissa
  ) public view virtual override returns (uint256) {
    uint256 oneMinusReserveFactor = uint256(1e18).sub(reserveFactorMantissa);
    uint256 borrowRate = getBorrowRateInternal(cash, borrows, reserves);
    uint256 rateToPool = borrowRate.mul(oneMinusReserveFactor).div(1e18);
    return utilizationRate(cash, borrows, reserves).mul(rateToPool).div(1e18);
  }

  /**
   * @notice Internal function to update the parameters of the interest rate model
   * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
   * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
   * @param jumpMultiplierPerYear The multiplierPerSecond after hitting a specified utilization point
   * @param kink_ The utilization point at which the jump multiplier is applied
   */
  function _updateJumpRateModelInternal(
    uint256 baseRatePerYear,
    uint256 multiplierPerYear,
    uint256 jumpMultiplierPerYear,
    uint256 kink_
  ) internal {
    baseRatePerSecond = baseRatePerYear.mul(1e18).div(secondsPerYear).div(1e18);
    multiplierPerSecond = multiplierPerYear.mul(1e18).div(secondsPerYear).div(1e18);
    jumpMultiplierPerSecond = jumpMultiplierPerYear.mul(1e18).div(secondsPerYear).div(1e18);
    kink = kink_;

    emit NewInterestParams(baseRatePerSecond, multiplierPerSecond, jumpMultiplierPerSecond, kink);
  }

  /**
   * @notice Calculates the current borrow rate per block
   * @param cash The amount of cash in the market
   * @param borrows The amount of borrows in the market
   * @param reserves The amount of reserves in the market
   * @return The borrow rate percentage per block as a mantissa (scaled by 1e18)
   */
  function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) external view override returns (uint256) {
    return getBorrowRateInternal(cash, borrows, reserves);
  }
}
