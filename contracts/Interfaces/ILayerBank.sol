pragma solidity ^0.8.19;

interface ILayerBank {
  function priceOf(address token) external view returns (uint256);
}
