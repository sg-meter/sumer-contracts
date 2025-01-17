// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';

interface IStCore {
  function earn() external view returns (address);
}

interface IEarn {
  function getCurrentExchangeRate() external view returns (uint256);
}

contract stCoreAdapter is PriceAdapter {
  uint256 constant EXP_SCALE = 1e18;

  constructor(address _correlatedToken /* stCore */, address _underlyingToken /* WCORE */) {
    correlatedToken = _correlatedToken;
    underlyingToken = _underlyingToken;
  }

  /**
   * @notice Gets underlying token amount for 1e18 correlated token
   * @return amount Amount of underlying token
   */
  function exchangeRate() public view override returns (uint256) {
    address earn = IStCore(correlatedToken).earn();
    return (IEarn(earn).getCurrentExchangeRate() * EXP_SCALE) / 1e6;
  }
}
