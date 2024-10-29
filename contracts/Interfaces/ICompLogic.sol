pragma solidity ^0.8.19;

interface ICompLogic {
  struct Exp {
    uint256 mantissa;
  }
  function setCompSpeed(address cToken, uint256 supplySpeed, uint256 borrowSpeed) external;

  function updateCompSupplyIndex(address cToken) external;

  function updateCompBorrowIndex(address cToken, Exp memory marketBorrowIndex) external;

  function distributeSupplierComp(address cToken, address supplier) external;

  function distributeBorrowerComp(address cToken, address borrower, Exp memory marketBorrowIndex) external;

  function initializeMarket(address cToken, uint32 blockNumber) external;

  function uninitializeMarket(address cToken) external;

  function getHypotheticalSafeLimit(
    address account,
    address cTokenModify,
    uint256 intraSafeLimitMantissa,
    uint256 interSafeLimitMantissa
  ) external view returns (uint256);
}
