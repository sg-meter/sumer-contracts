// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

enum Version {
  V0,
  V1,
  V2, // packed asset group
  V3, // added interMintRate into asset group
  V4 // use interMintSwitch instead of interMintRate
}

struct GroupVar {
  uint8 groupId;
  uint256 cDepositVal;
  uint256 cBorrowVal;
  uint256 suDepositVal;
  uint256 suBorrowVal;
  uint256 intraCRate;
  uint256 intraMintRate;
  uint256 intraSuRate;
  uint256 interCRate;
  uint256 interSuRate;
}

/// @notice AssetGroup, contains information of groupName and rateMantissas
struct AssetGroupDeprecated {
  uint8 groupId;
  string groupName;
  uint256 intraCRateMantissa;
  uint256 intraMintRateMantissa;
  uint256 intraSuRateMantissa;
  uint256 interCRateMantissa;
  uint256 interSuRateMantissa;
  bool exist;
}

/// @notice NewAssetGroup, contains information of groupName and rateMantissas
struct CompactAssetGroup {
  uint8 groupId;
  uint16 intraCRatePercent;
  uint16 intraMintRatePercent;
  uint16 intraSuRatePercent;
  uint16 interCRatePercent;
  uint16 interSuRatePercent;
}

struct GlobalConfig {
  uint16 closeFactorPercent; // percent decimals(4)
  uint32 minCloseValue; // usd value decimals(0)
  uint32 minSuBorrowValue; // usd value decimals(0)
  uint32 minWaitBeforeLiquidatable; // seconds decimals(0)
  uint8 largestGroupId;
}

struct MarketConfig {
  bool mintPaused;
  bool borrowPaused;
  bool transferPaused;
  bool seizePaused;
  uint120 borrowCap; //
  uint120 supplyCap;
}

struct LiquidationIncentive {
  uint16 heteroPercent;
  uint16 homoPercent;
  uint16 sutokenPercent;
}

interface IComptroller {
  /*** Assets You Are In ***/
  function isComptroller() external view returns (bool);

  function markets(address) external view returns (bool, uint8, bool);

  function getAllMarkets() external view returns (address[] memory);

  function oracle() external view returns (address);

  function redemptionManager() external view returns (address);

  function enterMarkets(address[] calldata cTokens) external;

  function exitMarket(address cToken) external;

  // function getAssetsIn(address) external view returns (ICToken[] memory);
  function claimSumer(address) external;

  function compAccrued(address) external view returns (uint256);

  function getAssetsIn(address account) external view returns (address[] memory);

  function timelock() external view returns (address);

  function getUnderlyingPriceNormalized(address cToken) external view returns (uint256);
  /*** Policy Hooks ***/

  function mintAllowed(address cToken, address minter, uint256 mintAmount) external;

  function redeemAllowed(address cToken, address redeemer, uint256 redeemTokens) external;
  function redeemVerify(address cToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens) external;

  function borrowAllowed(address cToken, address borrower, uint256 borrowAmount) external;
  function borrowVerify(address borrower, uint borrowAmount) external;

  function repayBorrowAllowed(address cToken, address payer, address borrower, uint256 repayAmount) external;
  function repayBorrowVerify(
    address cToken,
    address payer,
    address borrower,
    uint actualRepayAmount,
    uint borrowIndex
  ) external;

  function seizeAllowed(
    address cTokenCollateral,
    address cTokenBorrowed,
    address liquidator,
    address borrower,
    uint256 seizeTokens
  ) external;
  function seizeVerify(
    address cTokenCollateral,
    address cTokenBorrowed,
    address liquidator,
    address borrower,
    uint seizeTokens
  ) external;

  function transferAllowed(address cToken, address src, address dst, uint256 transferTokens) external;

  /*** Liquidity/Liquidation Calculations ***/

  function liquidationIncentive() external view returns (LiquidationIncentive memory);

  function isListed(address asset) external view returns (bool);

  function getHypotheticalAccountLiquidity(
    address account,
    address cTokenModify,
    uint256 redeemTokens,
    uint256 borrowAmount
  ) external view returns (uint256, uint256);

  // function _getMarketBorrowCap(address cToken) external view returns (uint256);

  /// @notice Emitted when an action is paused on a market
  event ActionPaused(address cToken, string action, bool pauseState);

  /// @notice Emitted when borrow cap for a cToken is changed
  event NewBorrowCap(address indexed cToken, uint256 newBorrowCap);

  /// @notice Emitted when borrow cap guardian is changed
  event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

  /// @notice Emitted when pause guardian is changed
  event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

  event RemoveAssetGroup(uint8 indexed groupId, uint8 equalAssetsGroupNum);

  function assetGroup(uint8 groupId) external view returns (CompactAssetGroup memory);

  function marketConfig(address cToken) external view returns (MarketConfig memory);

  function liquidateBorrowAllowed(
    address cTokenBorrowed,
    address cTokenCollateral,
    address liquidator,
    address borrower,
    uint256 repayAmount
  ) external view;
  function liquidateBorrowVerify(
    address cTokenBorrowed,
    address cTokenCollateral,
    address liquidator,
    address borrower,
    uint repayAmount,
    uint seizeTokens
  ) external;

  function globalConfig() external view returns (GlobalConfig memory);

  function interMintAllowed() external view returns (bool);
}
