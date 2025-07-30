// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';

interface ICoreVault {
  function exchangeCore(uint256) external view returns (uint256);
}

interface IDualCore {
  function coreVault() external view returns (address);
}

contract dualCoreAdapter is PriceAdapter {
  uint256 constant EXP_SCALE = 1e18;
  address public immutable coreVault;

  constructor(address _correlatedToken /* dualCore */, address _underlyingToken /* WCORE */) {
    correlatedToken = _correlatedToken;
    underlyingToken = _underlyingToken;
    coreVault = IDualCore(correlatedToken).coreVault();
  }

  /**
   * @notice Gets underlying token amount for 1e18 correlated token
   * @return amount Amount of underlying token
   */
  function exchangeRate() public view override returns (uint256) {
    return ICoreVault(coreVault).exchangeCore(1e18);
  }
}
