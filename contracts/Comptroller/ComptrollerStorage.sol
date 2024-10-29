// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import '../Interfaces/IComptroller.sol';
import '../Interfaces/ICompLogic.sol';
import '../Interfaces/IPriceOracle.sol';
import '../Interfaces/IRedemptionManager.sol';

contract ComptrollerStorage {
  /// @notice Indicator that this is a Comptroller contract (for inspection)
  bool public constant isComptroller = true;
  uint256 internal constant percentScale = 1e14;
  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');
  uint256 internal constant expScale = 1e18;

  // from AccessControlEnumerableUpgradeable
  uint256[50] private __gap;

  // uint256 closeFactorMantissa; // 201
  // uint256 heteroLiquidationIncentiveMantissa; // 202
  uint256[2] private gap0; // 201-202

  /**
   * @notice Per-account mapping of "assets you are in", capped by maxAssets
   */
  mapping(address => address[]) public accountAssets; // 203
  /// @notice Whether or not this market is listed
  /// @notice Per-market mapping of "accounts in this asset"
  /// @notice Whether or not this market receives COMP
  struct Market {
    bool isListed;
    uint8 assetGroupId;
    mapping(address => bool) accountMembership;
    bool isComped;
  }

  /**
   * @notice Official mapping of cTokens -> Market metadata
   * @dev Used e.g. to determine if a market is supported
   */
  mapping(address => Market) public markets; // 204

  /// @notice A list of all markets
  address[] public allMarkets; // 205

  // mapping(address => uint256) public maxSupply; // 206
  // uint256 internal homoLiquidationIncentiveMantissa; // 207
  // uint256 internal sutokenLiquidationIncentiveMantissa; // 208
  uint256[3] private gap1;

  address public governanceToken; // 209

  // uint256 public suTokenRateMantissa; // 210
  // AssetGroupDeprecated[] public _eqAssetGroupsDeprecated; // 211
  // mapping(uint8 => uint8) public assetGroupIdToIndex; // 212
  uint256[3] private gap22;

  address public pauseGuardian; // 213
  // bool private _mintGuardianPaused;
  // bool private _borrowGuardianPaused;
  // bool private transferGuardianPaused;
  // bool private seizeGuardianPaused;
  // mapping(address => bool) private mintGuardianPaused; // 214
  // mapping(address => bool) private borrowGuardianPaused; // 215
  // address public borrowCapGuardian; // 216
  // mapping(address => uint256) public borrowCaps; // 217
  uint256[4] private gap3;

  // additional variables
  ICompLogic public compLogic; // 218
  IPriceOracle public oracle; // 219

  // IAccountLiquidity public accountLiquidity; // 220
  uint256 private gap4; // 220

  address public timelock; // 221
  IRedemptionManager public redemptionManager; // 222

  // uint256 public minSuBorrowValue; // 223
  // bool protocolPaused; // 224
  // uint256 public minCloseValue; // 225
  uint256[3] private gap5; // 223-225

  // ctoken => last borrowed at timestamp
  mapping(address => uint48) public lastBorrowedAt; // 226

  // uint48 public minWaitBeforeLiquidatable; // 227
  uint256 private gap6;

  mapping(uint8 => CompactAssetGroup) public assetGroup; // groupId => asset group 228
  mapping(address => MarketConfig) public marketConfig; // ctoken => market configs & pause switches 229

  GlobalConfig public globalConfig; // 230
  LiquidationIncentive public liquidationIncentive; // 231

  bool public interMintAllowed; //
}
