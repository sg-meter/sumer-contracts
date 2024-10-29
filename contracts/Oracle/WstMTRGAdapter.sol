// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';

interface IWstMTRG {
  function stMTRGPerToken() external view returns (uint256);
}

contract WstMTRGAdapter is PriceAdapter {
  constructor(address _wstMTRG, address _stMTRG) {
    correlatedToken = _wstMTRG;
    underlyingToken = _stMTRG;
  }

  /**
   * @notice Gets the stMTRG for 1 wstMTRG
   * @return amount Amount of stMTRG
   */
  function exchangeRate() public view override returns (uint256) {
    return IWstMTRG(correlatedToken).stMTRGPerToken();
  }
}
