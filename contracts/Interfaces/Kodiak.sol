pragma solidity ^0.8.0;

interface IKodiakIsland {
  function getUnderlyingBalances() external view returns (uint256 amount0Current, uint256 amount1Current);
  function token0() external view returns (address);
  function token1() external view returns (address);
  function totalSupply() external view returns (uint256);
  function decimals() external view returns (uint8);
}
