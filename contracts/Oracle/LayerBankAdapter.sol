// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';

interface ILayerBank {
  function priceOf(address token) external view returns (uint256);
}

contract LayerBankAdapter is PriceAdapter {
  address public feedAddr;
  constructor(address _correlatedToken /* Token */, address _underlyingToken /* USD */, address _feedAddr) {
    correlatedToken = _correlatedToken;
    underlyingToken = _underlyingToken;
    feedAddr = _feedAddr;
  }

  /**
   * @notice Gets underlying token amount for 1e18 correlated token
   * @return amount Amount of underlying token
   */
  function exchangeRate() public view override returns (uint256) {
    return ILayerBank(feedAddr).priceOf(correlatedToken);
  }
}
