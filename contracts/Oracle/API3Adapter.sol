// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';
import '@openzeppelin/contracts/access/Ownable2Step.sol';

/// @dev See DapiProxy.sol for comments about usage
interface IAPI3Proxy {
  function read() external view returns (int224 value, uint32 timestamp);

  function api3ServerV1() external view returns (address);
}

contract API3Adapter is PriceAdapter, Ownable2Step {
  uint256 constant EXP_SCALE = 1e18;
  address constant usdToken = 0x1111111111111111111111111111111111111111;
  address proxy;

  error InvalidPrice();
  error InvalidProxy();

  constructor(address _correlatedToken, address _underlyingToken /* not used */) {
    correlatedToken = _correlatedToken;
    underlyingToken = usdToken;
  }

  function setAPI3Proxy(address _proxy) external onlyOwner {
    proxy = _proxy;
  }

  /**
   * @notice Gets underlying token amount for 1e18 correlated token
   * @return amount Amount of underlying token
   */
  function exchangeRate() public view override returns (uint256) {
    if (proxy == address(0)) {
      revert InvalidProxy();
    }
    (int224 price, uint32 timestamp) = IAPI3Proxy(proxy).read();
    // TODO: check timestamp to make sure it's not a stale price
    if (price < 0) {
      revert InvalidPrice();
    }
    return uint256(int256(price));
  }
}
