// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';

interface IStEUR {
  function previewRedeem(uint256 shares) external view returns (uint256);
}

contract stEURAdapter is PriceAdapter {
  uint256 constant EXP_SCALE = 1e18;

  constructor(address _correlatedToken /* stEUR */, address _underlyingToken /* sgEUR (EURA) */) {
    correlatedToken = _correlatedToken;
    underlyingToken = _underlyingToken;
  }

  /**
   * @notice Gets the stEUR for 1 sgEUR
   * @return amount Amount of stEUR
   */
  function exchangeRate() public view override returns (uint256) {
    return IStEUR(correlatedToken).previewRedeem(EXP_SCALE);
  }
}
