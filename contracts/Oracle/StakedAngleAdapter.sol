// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';

interface IStToken {
  function previewRedeem(uint256 shares) external view returns (uint256);
}

contract StakedAngleAdapter is PriceAdapter {
  uint256 constant EXP_SCALE = 1e18;

  constructor(
    address _correlatedToken /* st token (e.g. stUSD) */,
    address _underlyingToken /* sg token (e.g. sgUSD / USDA) */
  ) {
    correlatedToken = _correlatedToken;
    underlyingToken = _underlyingToken;
  }

  /**
   * @notice Gets the sg token for 1 st token
   * @return amount Amount of sg token
   */
  function exchangeRate() public view override returns (uint256) {
    return IStToken(correlatedToken).previewRedeem(EXP_SCALE);
  }
}
