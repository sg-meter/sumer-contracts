// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';

interface IStETH {
  function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
  function decimals() external view returns (uint8);
}

contract WstETHAdapter is PriceAdapter {
  uint256 constant EXP_SCALE = 1e18;

  constructor(address _wstETH, address _stETH) {
    correlatedToken = _wstETH;
    underlyingToken = _stETH;
  }

  /**
   * @notice Gets the stETH for 1 wstETH
   * @return amount Amount of stETH
   */
  function exchangeRate() public view override returns (uint256) {
    return IStETH(underlyingToken).getPooledEthByShares(EXP_SCALE);
  }
}
