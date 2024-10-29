// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.0;

interface IPendlePtOracle {
  function getPtToSyRate(address market, uint32 duration) external view returns (uint256);
  function getOracleState(
    address market,
    uint32 duration
  )
    external
    view
    returns (bool increaseCardinalityRequired, uint16 cardinalityRequired, bool oldestObservationSatisfied);
}
