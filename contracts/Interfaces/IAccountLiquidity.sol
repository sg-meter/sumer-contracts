pragma solidity ^0.8.19;

interface IAccountLiquidity {
  function getHypotheticalAccountLiquidity(
    address account,
    address cTokenModify,
    uint256 redeemTokens,
    uint256 borrowAmount
  ) external view returns (uint256, uint256);

  function getHypotheticalSafeLimit(
    address account,
    address cTokenModify,
    uint256 intraSafeLimitMantissa,
    uint256 interSafeLimitMantissa
  ) external view returns (uint256);

  // function getIntermediateGroupSummary(
  //   address account,
  //   address cTokenModify,
  //   uint256 redeemTokens,
  //   uint256 borrowAmount
  // ) external view returns (uint256, uint256, AccountGroupLocalVars memory);

  // function getHypotheticalGroupSummary(
  //   address account,
  //   address cTokenModify,
  //   uint256 redeemTokens,
  //   uint256 borrowAmount
  // ) external view returns (uint256, uint256, AccountGroupLocalVars memory);
}
