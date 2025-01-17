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
   * @notice Gets underlying token amount for 1e18 correlated token
   * @return amount Amount of underlying token
   */
  function exchangeRate() public view override returns (uint256) {
    return IWstMTRG(correlatedToken).stMTRGPerToken();
  }
}
