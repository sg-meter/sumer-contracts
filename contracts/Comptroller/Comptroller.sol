// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import '../Interfaces/ICompLogic.sol';
import '../Interfaces/IAccountLiquidity.sol';
import '../Interfaces/IRedemptionManager.sol';
import './ComptrollerStorage.sol';
import '../Exponential/ExponentialNoErrorNew.sol';
import '../Interfaces/ICTokenExternal.sol';
import '../Interfaces/IPriceOracle.sol';
import '@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol';
import '../Interfaces/IComptroller.sol';
import '../SumerErrors.sol';

/**
 * @title Compound's Comptroller Contract
 * @author Compound
 */
contract Comptroller is AccessControlEnumerableUpgradeable, ComptrollerStorage, ExponentialNoErrorNew, SumerErrors {
  // additional variables
  ICompLogic public compLogic;
  IPriceOracle public oracle;
  IAccountLiquidity public accountLiquidity;

  bytes32 public constant COMP_LOGIC = keccak256('COMP_LOGIC');

  address public timelock;

  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');
  bytes32 public constant CAPPER_ROLE = keccak256('CAPPER_ROLE');

  IRedemptionManager public redemptionManager;

  // minSuBorrowValue is the USD value for borrowed sutoken in one call
  uint256 public minSuBorrowValue;

  bool protocolPaused;

  // minCloseValue is the USD value for liquidation close
  uint256 public minCloseValue;

  mapping(address => uint48) public lastBorrowedAt;

  uint48 public minWaitBeforeLiquidatable; // seconds before borrow become liquidatable

  // End of additional variables

  /// @notice Emitted when an action is paused on a market
  event ActionPaused(address cToken, string action, bool pauseState);

  /// @notice Emitted when borrow cap for a cToken is changed
  event NewBorrowCap(address indexed cToken, uint256 newBorrowCap);

  /// @notice Emitted when borrow cap guardian is changed
  event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

  /// @notice Emitted when pause guardian is changed
  event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

  event RemoveAssetGroup(uint8 indexed groupId, uint8 equalAssetsGroupNum);

  event NewAssetGroup(
    uint8 indexed groupId,
    string indexed groupName,
    uint256 intraCRateMantissa,
    uint256 intraMintRateMantissa,
    uint256 intraSuRateMantissa,
    uint256 interCRateMantissa,
    uint256 interSuRateMantissa,
    uint8 assetsGroupNum
  );

  event NewCompLogic(address oldAddress, address newAddress);
  event NewAccountLiquidity(address oldAddress, address newAddress);
  event NewRedemptionManager(address oldAddress, address newAddress);

  event NewMinSuBorrowValue(uint256 oldValue, uint256 newValue);
  event NewMinCloseValue(uint256 oldValue, uint256 newValue);
  event NewMinWaitBeforeLiquidatable(uint48 oldValue, uint48 newValue);

  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _admin,
    IPriceOracle _oracle,
    address _gov,
    ICompLogic _compLogic,
    IAccountLiquidity _accountLiquidity,
    uint256 _closeFactorMantissa,
    uint256 _heteroLiquidationIncentiveMantissa,
    uint256 _homoLiquidationIncentiveMantissa,
    uint256 _sutokenLiquidationIncentiveMantissa
  ) external initializer {
    _setupRole(DEFAULT_ADMIN_ROLE, _admin);

    governanceToken = _gov;
    suTokenRateMantissa = 10 ** 18;
    // Set comptroller's oracle to newOracle
    oracle = _oracle;
    // Emit NewPriceOracle(oldOracle, newOracle)
    emit NewPriceOracle(address(0), address(_oracle));

    compLogic = _compLogic;
    emit NewCompLogic(address(0), address(compLogic));

    accountLiquidity = _accountLiquidity;
    emit NewAccountLiquidity(address(0), address(accountLiquidity));

    closeFactorMantissa = _closeFactorMantissa;
    emit NewCloseFactor(0, _closeFactorMantissa);

    // Set liquidation incentive to new incentive
    heteroLiquidationIncentiveMantissa = _heteroLiquidationIncentiveMantissa;
    homoLiquidationIncentiveMantissa = _homoLiquidationIncentiveMantissa;
    sutokenLiquidationIncentiveMantissa = _sutokenLiquidationIncentiveMantissa;

    // Emit event with old incentive, new incentive
    emit NewLiquidationIncentive(
      0,
      _heteroLiquidationIncentiveMantissa,
      0,
      _homoLiquidationIncentiveMantissa,
      0,
      _sutokenLiquidationIncentiveMantissa
    );

    minSuBorrowValue = 100e18;
    emit NewMinSuBorrowValue(0, minSuBorrowValue);

    minCloseValue = 100e18;
    emit NewMinCloseValue(0, minCloseValue);

    minWaitBeforeLiquidatable = 60; // 1min
    emit NewMinWaitBeforeLiquidatable(0, minWaitBeforeLiquidatable);
  }

  /*** Assets You Are In ***/
  /**
   * @notice Returns the assets an account has entered
   * @param account The address of the account to pull assets for
   * @return A dynamic list with the assets the account has entered
   */
  function getAssetsIn(address account) external view returns (address[] memory) {
    address[] memory assetsIn = accountAssets[account];

    return assetsIn;
  }

  /**
   * @notice Returns whether the given account is entered in the given asset
   * @param account The address of the account to check
   * @param cToken The cToken to check
   * @return True if the account is in the asset, otherwise false.
   */
  function checkMembership(address account, address cToken) external view returns (bool) {
    return markets[cToken].accountMembership[account];
  }

  function isListed(address asset) public view returns (bool) {
    return markets[asset].isListed;
  }

  function marketGroupId(address asset) external view returns (uint8) {
    return markets[asset].assetGroupId;
  }

  /*************************/
  /*** Markets functions ***/
  /*************************/
  /**
   * @notice Return all of the markets
   * @dev The automatic getter may be used to access an individual market.
   * @return The list of market addresses
   */
  function getAllMarkets() public view returns (address[] memory) {
    return allMarkets;
  }

  /**
   * @notice Add assets to be included in account liquidity calculation
   * @param cTokens The list of addresses of the cToken markets to be enabled
   * @return Success indicator for whether each corresponding market was entered
   */
  function enterMarkets(address[] memory cTokens) public returns (uint256[] memory) {
    uint256 len = cTokens.length;

    uint256[] memory results = new uint256[](len);
    for (uint256 i = 0; i < len; ++i) {
      address cToken = cTokens[i];
      //IIComptroller(address(this))IComptroller.AssetGroup memory eqAssets = IComptroller(address(this))getAssetGroup(cToken);
      //results[i] = uint(addToMarketInternal(cToken, msg.sender, eqAssets.groupName, eqAssets.rateMantissas));
      results[i] = uint256(addToMarketInternal(cToken, msg.sender));
    }

    return results;
  }

  /**
   * @notice Add the market to the borrower's "assets in" for liquidity calculations
   * @param cToken The market to enter
   * @param borrower The address of the account to modify
   * @return Success indicator for whether the market was entered
   */
  function addToMarketInternal(address cToken, address borrower) internal returns (uint256) {
    Market storage marketToJoin = markets[cToken];

    require(marketToJoin.isListed, MARKET_NOT_LISTED);

    if (marketToJoin.accountMembership[borrower]) {
      // already joined
      return uint256(0);
    }

    // survived the gauntlet, add to list
    // NOTE: we store these somewhat redundantly as a significant optimization
    //  this avoids having to iterate through the list for the most common use cases
    //  that is, only when we need to perform liquidity checks
    //  and not whenever we want to check if an account is in a particular market
    marketToJoin.accountMembership[borrower] = true;
    accountAssets[borrower].push(cToken);

    // all tokens are grouped with equal assets.
    //addToEqualAssetGroupInternal(cToken, borrower, eqAssetGroup, rateMantissa);

    emit MarketEntered(cToken, borrower);

    return uint256(0);
  }

  /**
   * @notice Removes asset from sender's account liquidity calculation
   * @dev Sender must not have an outstanding borrow balance in the asset,
   *  or be providing necessary collateral for an outstanding borrow.
   * @param cTokenAddress The address of the asset to be removed
   * @return Whether or not the account successfully exited the market
   */
  function exitMarket(address cTokenAddress) external returns (uint256) {
    address cToken = cTokenAddress;
    /* Get sender tokensHeld and amountOwed underlying from the cToken */
    (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = ICToken(cToken).getAccountSnapshot(msg.sender);
    require(oErr == 0, SNAPSHOT_ERROR); // semi-opaque error code

    /* Fail if the sender has a borrow balance */
    if (amountOwed != 0) {
      revert CantExitMarketWithNonZeroBorrowBalance();
    }
    /* Fail if the sender is not permitted to redeem all of their tokens */
    redeemAllowedInternal(cTokenAddress, msg.sender, tokensHeld);

    Market storage marketToExit = markets[cToken];

    /* Return true if the sender is not already ‘in’ the market */
    if (!marketToExit.accountMembership[msg.sender]) {
      return uint256(0);
    }

    /* Set cToken account membership to false */
    delete marketToExit.accountMembership[msg.sender];

    /* Delete cToken from the account’s list of assets */
    // load into memory for faster iteration
    address[] memory userAssetList = accountAssets[msg.sender];
    uint256 len = userAssetList.length;
    uint256 assetIndex = len;
    for (uint256 i = 0; i < len; ++i) {
      if (userAssetList[i] == cToken) {
        assetIndex = i;
        break;
      }
    }

    // We *must* have found the asset in the list or our redundant data structure is broken
    assert(assetIndex < len);

    // copy last item in list to location of item to be removed, reduce length by 1
    address[] storage storedList = accountAssets[msg.sender];
    storedList[assetIndex] = storedList[storedList.length - 1];
    storedList.pop();

    // remove the same
    //exitEqualAssetGroupInternal(cTokenAddress, msg.sender);

    emit MarketExited(cToken, msg.sender);

    return uint256(0);
  }

  function _addMarketInternal(address cToken) internal {
    for (uint256 i = 0; i < allMarkets.length; ++i) {
      if (allMarkets[i] == cToken) {
        revert MarketAlreadyListed();
      }
    }
    allMarkets.push(cToken);
  }

  /**
   * @notice Add the market to the markets mapping and set it as listed
   * @dev Admin function to set isListed and add support for the market
   * @param cToken The address of the market (token) to list
   * @return uint 0=success, otherwise a failure. (See enum uint256 for details)
   */
  function _supportMarket(
    address cToken,
    uint8 groupId,
    uint256 borrowCap,
    uint256 supplyCap
  ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
    if (markets[cToken].isListed) {
      revert MarketAlreadyListed();
    }
    if (groupId <= 0) {
      revert InvalidGroupId();
    }

    // ICToken(cToken).isCToken(); // Sanity check to make sure its really a address
    (bool success, ) = cToken.call(abi.encodeWithSignature('isCToken()'));
    require(success && isContract(cToken), 'contract error');

    // Note that isComped is not in active use anymore
    // markets[cToken] = Market({isListed: true, isComped: false, assetGroupId: groupId});
    Market storage market = markets[cToken];
    market.isListed = true;
    market.assetGroupId = groupId;

    _addMarketInternal(cToken);
    _initializeMarket(cToken);

    emit MarketListed(cToken);

    borrowCaps[cToken] = borrowCap;
    emit NewBorrowCap(cToken, borrowCap);

    maxSupply[cToken] = supplyCap;
    emit SetMaxSupply(cToken, supplyCap);

    return uint256(0);
  }

  function _initializeMarket(address cToken) internal {
    uint32 blockNumber = safe32(block.number, 'block number exceeds 32 bits');
    compLogic.initializeMarket(cToken, blockNumber);
  }

  /**
   * @notice Update related assets to be included in mentioned account liquidity calculation
   * @param accounts The list of accounts to be updated
   */
  function enterMarketsForAll(address[] memory accounts) public onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 len = accounts.length;

    for (uint256 k = 0; k < allMarkets.length; k++) {
      address cToken = allMarkets[k];
      for (uint256 i = 0; i < len; i++) {
        address account = accounts[i];
        if (ICToken(cToken).balanceOf(account) > 0 || ICToken(cToken).borrowBalanceCurrent(account) > 0) {
          addToMarketInternal(cToken, account);
        }
      }
    }
  }

  /******************************************/
  /*** Liquidity/Liquidation Calculations ***/
  /******************************************/
  /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
  function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256) {
    (uint256 liquidity, uint256 shortfall) = accountLiquidity.getHypotheticalAccountLiquidity(
      account,
      address(0),
      0,
      0
    );

    return (uint256(0), liquidity, shortfall);
  }

  function getAccountSafeLimit(
    address account,
    address cTokenTarget,
    uint256 intraSafeLimitMantissa,
    uint256 interSafeLimitMantissa
  ) external view returns (uint256) {
    return
      accountLiquidity.getHypotheticalSafeLimit(account, cTokenTarget, intraSafeLimitMantissa, interSafeLimitMantissa);
  }

  /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param cTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
  function getHypotheticalAccountLiquidity(
    address account,
    address cTokenModify,
    uint256 redeemTokens,
    uint256 borrowAmount
  ) external view returns (uint256, uint256, uint256) {
    (uint256 liquidity, uint256 shortfall) = accountLiquidity.getHypotheticalAccountLiquidity(
      account,
      address(cTokenModify),
      redeemTokens,
      borrowAmount
    );
    return (uint256(0), liquidity, shortfall);
  }

  /***********************/
  /*** Admin Functions ***/
  /***********************/
  function setTimelock(address _timelock) public onlyRole(DEFAULT_ADMIN_ROLE) {
    timelock = _timelock;
  }

  /**
   * @notice Sets a new price oracle for the comptroller
   * @dev Admin function to set a new price oracle
   * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
   */
  function _setPriceOracle(IPriceOracle newOracle) public onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
    // Track the old oracle for the comptroller
    IPriceOracle oldOracle = oracle;
    // Set comptroller's oracle to newOracle
    oracle = newOracle;
    // Emit NewPriceOracle(oldOracle, newOracle)
    emit NewPriceOracle(address(oldOracle), address(newOracle));
    return uint256(0);
  }

  /**
   * @notice Sets the closeFactor used when liquidating borrows
   * @dev Admin function to set closeFactor
   * @param newCloseFactorMantissa New close factor, scaled by 1e18
   * @return uint 0=success, otherwise a failure
   */
  function _setCloseFactor(uint256 newCloseFactorMantissa) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
    if (newCloseFactorMantissa <= 0) {
      revert InvalidCloseFactor();
    }
    uint256 oldCloseFactorMantissa = closeFactorMantissa;
    closeFactorMantissa = newCloseFactorMantissa;
    emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

    return uint256(0);
  }

  /**
   * @notice Sets liquidationIncentive
   * @dev Admin function to set liquidationIncentive
   * @param newHeteroLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18 for hetero assets
   * @param newHomoLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18 for homo assets
   * @param newSutokenLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18 for sutoken assets
   * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
   */
  function _setLiquidationIncentive(
    uint256 newHeteroLiquidationIncentiveMantissa,
    uint256 newHomoLiquidationIncentiveMantissa,
    uint256 newSutokenLiquidationIncentiveMantissa
  ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
    // Save current value for use in log
    uint256 oldHetero = heteroLiquidationIncentiveMantissa;
    uint256 oldHomo = homoLiquidationIncentiveMantissa;
    uint256 oldSutoken = sutokenLiquidationIncentiveMantissa;
    // Set liquidation incentive to new incentive
    heteroLiquidationIncentiveMantissa = newHeteroLiquidationIncentiveMantissa;
    homoLiquidationIncentiveMantissa = newHomoLiquidationIncentiveMantissa;
    sutokenLiquidationIncentiveMantissa = newSutokenLiquidationIncentiveMantissa;
    // Emit event with old incentive, new incentive
    emit NewLiquidationIncentive(
      oldHetero,
      newHeteroLiquidationIncentiveMantissa,
      oldHomo,
      newHomoLiquidationIncentiveMantissa,
      oldSutoken,
      newSutokenLiquidationIncentiveMantissa
    );
    return uint256(0);
  }

  function setCompSpeed(
    address cToken,
    uint256 supplySpeed,
    uint256 borrowSpeed
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    compLogic.setCompSpeed(cToken, supplySpeed, borrowSpeed);
  }

  function setCompLogic(ICompLogic _compLogic) external onlyRole(DEFAULT_ADMIN_ROLE) {
    address oldAddress = address(compLogic);
    compLogic = _compLogic;
    emit NewCompLogic(oldAddress, address(compLogic));
  }

  function setAccountLiquidity(IAccountLiquidity _accountLiquidity) external onlyRole(DEFAULT_ADMIN_ROLE) {
    address oldAddress = address(accountLiquidity);
    accountLiquidity = _accountLiquidity;
    emit NewAccountLiquidity(oldAddress, address(accountLiquidity));
  }

  function setRedemptionManager(IRedemptionManager _redemptionManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
    address oldAddress = address(redemptionManager);
    redemptionManager = _redemptionManager;
    emit NewRedemptionManager(oldAddress, address(redemptionManager));
  }

  function setMinSuBorrowValue(uint256 _minSuBorrowValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (_minSuBorrowValue < 1e18) {
      revert InvalidMinSuBorrowValue();
    }
    uint256 oldValue = minSuBorrowValue;
    minSuBorrowValue = _minSuBorrowValue;
    emit NewMinSuBorrowValue(oldValue, minSuBorrowValue);
  }

  function setMinCloseValue(uint256 _minCloseValue) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 oldValue = minCloseValue;
    minCloseValue = _minCloseValue;
    emit NewMinCloseValue(oldValue, minCloseValue);
  }

  function setMinWaitBeforeLiquidatable(uint48 _minWaitBeforeLiquidatable) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint48 oldValue = minWaitBeforeLiquidatable;
    minWaitBeforeLiquidatable = _minWaitBeforeLiquidatable;
    emit NewMinWaitBeforeLiquidatable(oldValue, minWaitBeforeLiquidatable);
  }

  /**
   * @dev Returns true if `account` is a contract.
   *
   * [IMPORTANT]
   * ====
   * It is unsafe to assume that an address for which this function returns
   * false is an externally-owned account (EOA) and not a contract.
   *
   * Among others, `isContract` will return false for the following
   * types of addresses:
   *
   *  - an externally-owned account
   *  - a contract in construction
   *  - an address where a contract will be created
   *  - an address where a contract lived, but was destroyed
   * ====
   */
  function isContract(address account) internal view returns (bool) {
    return account.code.length > 0;
  }

  function liquidationIncentiveMantissa() public view returns (uint256, uint256, uint256) {
    return (heteroLiquidationIncentiveMantissa, homoLiquidationIncentiveMantissa, sutokenLiquidationIncentiveMantissa);
  }

  /***********************************/
  /*** Equal Asset Group functions ***/
  /***********************************/
  // function eqAssetGroup(uint8 groupId) public view returns (IComptroller.AssetGroup memory) {
  //   return _eqAssetGroups[assetGroupIdToIndex[groupId] - 1];
  // }

  function setAssetGroup(
    uint8 groupId,
    string memory groupName,
    uint256 intraCRateMantissa, // ctoken collateral rate for intra group ctoken liability
    uint256 intraMintRateMantissa, // ctoken collateral rate for intra group sutoken liability
    uint256 intraSuRateMantissa, // sutoken collateral rate for intra group ctoken liability
    uint256 interCRateMantissa, // ctoken collateral rate for inter group ctoken/sutoken liability
    uint256 interSuRateMantissa // sutoken collateral rate for inter group ctoken/sutoken liability
  ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
    if (_eqAssetGroups.length == 0) {
      _eqAssetGroups.push(IComptroller.AssetGroup(0, 'Invalid', 0, 0, 0, 0, 0, false));
    }
    uint8 index = assetGroupIdToIndex[groupId];
    if (
      index == 0 /* not exist */ ||
      index >= _eqAssetGroups.length /* invalid */ ||
      _eqAssetGroups[index].groupId != groupId /* mismatch */
    ) {
      // append new group
      _eqAssetGroups.push(
        IComptroller.AssetGroup(
          groupId,
          groupName,
          intraCRateMantissa,
          intraMintRateMantissa,
          intraSuRateMantissa,
          interCRateMantissa,
          interSuRateMantissa,
          true
        )
      );
      uint8 newIndex = uint8(_eqAssetGroups.length) - 1;
      assetGroupIdToIndex[groupId] = newIndex;

      emit NewAssetGroup(
        groupId,
        groupName,
        intraCRateMantissa,
        intraMintRateMantissa,
        intraSuRateMantissa,
        interCRateMantissa,
        interSuRateMantissa,
        newIndex
      );
    } else {
      if (_eqAssetGroups[index].groupId != groupId) {
        revert GroupIdMismatch();
      }
      // update existing group
      _eqAssetGroups[index] = IComptroller.AssetGroup(
        groupId,
        groupName,
        intraCRateMantissa,
        intraMintRateMantissa,
        intraSuRateMantissa,
        interCRateMantissa,
        interSuRateMantissa,
        true
      );
    }
    return 0;
  }

  function removeAssetGroup(uint8 groupId) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
    uint8 length = uint8(_eqAssetGroups.length);
    uint8 lastGroupId = _eqAssetGroups[length - 1].groupId;
    uint8 index = assetGroupIdToIndex[groupId];

    if (_eqAssetGroups[index].groupId == groupId) {
      revert InvalidGroupId();
    }
    _eqAssetGroups[index] = _eqAssetGroups[length - 1];
    assetGroupIdToIndex[lastGroupId] = index;
    _eqAssetGroups.pop();
    delete assetGroupIdToIndex[groupId];

    emit RemoveAssetGroup(groupId, length);
    return uint256(0);
  }

  function cleanAssetGroup() external onlyRole(DEFAULT_ADMIN_ROLE) {
    for (uint8 i = 0; i < _eqAssetGroups.length; i++) {
      uint8 groupId = _eqAssetGroups[i].groupId;
      delete assetGroupIdToIndex[groupId];
    }

    uint8 len = uint8(_eqAssetGroups.length);
    for (uint8 i = 0; i < len; i++) {
      _eqAssetGroups.pop();
    }
  }

  function getAssetGroup(uint8 groupId) public view returns (IComptroller.AssetGroup memory) {
    return _eqAssetGroups[assetGroupIdToIndex[groupId]];
  }

  function getAssetGroupNum() external view returns (uint8) {
    return uint8(_eqAssetGroups.length);
  }

  function getAllAssetGroup() external view returns (IComptroller.AssetGroup[] memory) {
    return _eqAssetGroups;
  }

  function getAssetGroupByIndex(uint8 groupIndex) external view returns (IComptroller.AssetGroup memory) {
    return _eqAssetGroups[groupIndex];
  }

  modifier onlyAdminOrPauser(bool state) {
    if (state) {
      if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
        revert OnlyAdmin();
      }
    } else {
      if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) {
        revert OnlyAdminOrPauser();
      }
    }
    _;
  }

  /**
   * @notice Admin function to change the Pause Guardian
   * @param newPauseGuardian The address of the new Pause Guardian
   * @return uint 0=success, otherwise a failure. (See enum Error for details)
   */
  function _setPauseGuardian(address newPauseGuardian) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
    if (newPauseGuardian == address(0)) {
      revert InvalidAddress();
    }

    // Save current value for inclusion in log
    address oldPauseGuardian = pauseGuardian;
    revokeRole(PAUSER_ROLE, oldPauseGuardian);

    // Store pauseGuardian with value newPauseGuardian
    pauseGuardian = newPauseGuardian;
    grantRole(PAUSER_ROLE, newPauseGuardian);

    // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
    emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

    return uint256(0);
  }

  function _getPauseGuardian() external view returns (address) {
    return pauseGuardian;
  }

  // Pause functions
  function _setProtocolPaused(bool state) external onlyAdminOrPauser(state) returns (bool) {
    protocolPaused = state;
    return state;
  }

  function _setMintPaused(ICToken cToken, bool state) external onlyAdminOrPauser(state) returns (bool) {
    mintGuardianPaused[address(cToken)] = state;
    emit ActionPaused(address(cToken), 'Mint', state);
    return state;
  }

  function _setBorrowPaused(ICToken cToken, bool state) external onlyAdminOrPauser(state) returns (bool) {
    borrowGuardianPaused[address(cToken)] = state;
    emit ActionPaused(address(cToken), 'Borrow', state);
    return state;
  }

  function _setTransferPaused(bool state) external onlyAdminOrPauser(state) returns (bool) {
    transferGuardianPaused = state;
    emit ActionPaused(address(0), 'Transfer', state);
    return state;
  }

  function _setSeizePaused(bool state) external onlyAdminOrPauser(state) returns (bool) {
    seizeGuardianPaused = state;
    emit ActionPaused(address(0), 'Seize', state);
    return state;
  }

  /**
   * @notice Return the address of the COMP token
   * @return The address of COMP
   */
  function getCompAddress() external view returns (address) {
    /*
        return 0xc00e94Cb662C3520282E6f5717214004A7f26888;
        */
    return governanceToken;
  }

  /**
   * @notice Return the address of the COMP token
   * @param _governanceToken The address of COMP(governance token)
   */
  function setGovTokenAddress(address _governanceToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
    //require(adminOrInitializing(), "only admin can set governanceToken");
    if (_governanceToken == address(0)) {
      revert InvalidAddress();
    }
    governanceToken = _governanceToken;
  }

  modifier onlyAdminOrCapper() {
    if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(CAPPER_ROLE, msg.sender)) {
      revert OnlyAdminOrCapper();
    }
    _;
  }

  /**
   * @notice Set the given borrow caps for the given cToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
   * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
   * @param cTokens The addresses of the markets (tokens) to change the borrow caps for
   * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
   */
  function _setMarketBorrowCaps(
    ICToken[] calldata cTokens,
    uint256[] calldata newBorrowCaps
  ) external onlyAdminOrCapper {
    uint256 numMarkets = cTokens.length;
    uint256 numBorrowCaps = newBorrowCaps.length;

    if (numMarkets == 0 || numMarkets != numBorrowCaps) {
      revert InvalidInput();
    }

    for (uint256 i = 0; i < numMarkets; i++) {
      borrowCaps[address(cTokens[i])] = newBorrowCaps[i];
      emit NewBorrowCap(address(cTokens[i]), newBorrowCaps[i]);
    }
  }

  function _setMaxSupply(
    ICToken[] calldata cTokens,
    uint256[] calldata newMaxSupplys
  ) external onlyAdminOrCapper returns (uint256) {
    uint256 numMarkets = cTokens.length;
    uint256 numMaxSupplys = newMaxSupplys.length;

    if (numMarkets == 0 || numMarkets != numMaxSupplys) {
      revert InvalidInput();
    }

    for (uint256 i = 0; i < numMarkets; i++) {
      maxSupply[address(cTokens[i])] = newMaxSupplys[i];
      emit SetMaxSupply(address(cTokens[i]), newMaxSupplys[i]);
    }

    return uint256(0);
  }

  /**
   * @notice Admin function to change the Borrow Cap Guardian
   * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
   */
  function _setBorrowCapGuardian(address newBorrowCapGuardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (newBorrowCapGuardian == address(0)) {
      revert InvalidAddress();
    }

    // Save current value for inclusion in log
    address oldBorrowCapGuardian = borrowCapGuardian;
    revokeRole(CAPPER_ROLE, oldBorrowCapGuardian);

    // Store borrowCapGuardian with value newBorrowCapGuardian
    borrowCapGuardian = newBorrowCapGuardian;
    grantRole(CAPPER_ROLE, newBorrowCapGuardian);

    // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
    emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
  }

  function _getBorrowCapGuardian() external view returns (address) {
    return borrowCapGuardian;
  }

  function getCollateralRate(address collateralToken, address liabilityToken) public view returns (uint256) {
    if (!markets[collateralToken].isListed) {
      revert MarketNotListed();
    }
    if (!markets[liabilityToken].isListed) {
      revert MarketNotListed();
    }

    uint8 collateralGroupId = markets[collateralToken].assetGroupId;
    uint8 liabilityGroupId = markets[liabilityToken].assetGroupId;
    bool collateralIsCToken = ICToken(collateralToken).isCToken();
    bool liabilityIsCToken = ICToken(liabilityToken).isCToken();

    if (collateralIsCToken) {
      // collateral is cToken
      if (collateralGroupId == liabilityGroupId) {
        // collaterl/liability is in the same group
        if (liabilityIsCToken) {
          return getAssetGroup(collateralGroupId).intraCRateMantissa;
        } else {
          return getAssetGroup(collateralGroupId).intraMintRateMantissa;
        }
      } else {
        // collateral/liability is not in the same group
        return getAssetGroup(collateralGroupId).interCRateMantissa;
      }
    } else {
      // collateral is suToken
      if (collateralGroupId == liabilityGroupId) {
        // collaterl/liability is in the same group
        return getAssetGroup(collateralGroupId).intraSuRateMantissa;
      } else {
        // collateral/liability is not in the same group
        return getAssetGroup(collateralGroupId).interSuRateMantissa;
      }
    }
  }

  /********************/
  /*** Policy Hooks ***/
  /********************/
  /**
   * @notice Checks if the account should be allowed to mint tokens in the given market
   * @param cToken The market to verify the mint against
   * @param minter The account which would get the minted tokens
   * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
   */
  function mintAllowed(address cToken, address minter, uint256 mintAmount) external {
    // Pausing is a very serious situation - we revert to sound the alarms
    if (protocolPaused) {
      revert ProtocolIsPaused();
    }
    if (mintGuardianPaused[cToken]) {
      revert MintPaused();
    }

    // Shh - currently unused: minter; mintAmount;

    require(markets[cToken].isListed, MARKET_NOT_LISTED);

    /* Get minter's cToken balance*/
    (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = ICToken(cToken).getAccountSnapshot(minter);
    require(oErr == 0, SNAPSHOT_ERROR); // semi-opaque error code

    // only enter market automatically at the first time
    if ((!markets[cToken].accountMembership[minter]) && (tokensHeld == 0) && (amountOwed == 0)) {
      // only cTokens may call mintAllowed if minter not in market
      if (msg.sender != cToken) {
        revert SenderMustBeCToken();
      }

      // attempt to add borrower to the market
      addToMarketInternal(msg.sender, minter);

      // it should be impossible to break the important invariant
      assert(markets[cToken].accountMembership[minter]);
    }

    // TODO: temporarily comment out for less gas usage
    // Keep the flywheel moving
    // compLogic.updateCompSupplyIndex(cToken);
    // compLogic.distributeSupplierComp(cToken, minter);

    if (
      !(maxSupply[cToken] == 0 ||
        (maxSupply[cToken] > 0 && ICToken(cToken).totalSupply() + mintAmount <= maxSupply[cToken]))
    ) {
      revert SupplyCapReached();
    }
  }

  /**
   * @notice Checks if the account should be allowed to redeem tokens in the given market
   * @param cToken The market to verify the redeem against
   * @param redeemer The account which would redeem the tokens
   * @param redeemTokens The number of cTokens to exchange for the underlying asset in the market
   */
  function redeemAllowed(address cToken, address redeemer, uint256 redeemTokens) external {
    redeemAllowedInternal(cToken, redeemer, redeemTokens);

    // TODO: temporarily comment out for less gas usage
    // Keep the flywheel moving
    // compLogic.updateCompSupplyIndex(cToken);
    // compLogic.distributeSupplierComp(cToken, redeemer);
  }

  function redeemAllowedInternal(address cToken, address redeemer, uint256 redeemTokens) internal view {
    require(markets[cToken].isListed, MARKET_NOT_LISTED);

    /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
    if (!markets[cToken].accountMembership[redeemer]) {
      return;
    }

    /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
    (, uint256 shortfall) = accountLiquidity.getHypotheticalAccountLiquidity(redeemer, cToken, redeemTokens, 0);
    if (shortfall > 0) {
      revert InsufficientCollateral();
    }
  }

  /**
   * @notice Validates redeem and reverts on rejection. May emit logs.
   * @param cToken Asset being redeemed
   * @param redeemer The address redeeming the tokens
   * @param redeemAmount The amount of the underlying asset being redeemed
   * @param redeemTokens The number of tokens being redeemed
   */
  // function redeemVerify(address cToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens) external {
  //   // Shh - currently unused: cToken; redeemer;

  //   // Require tokens is zero or amount is also zero
  //   if (redeemTokens == 0 && redeemAmount > 0) {
  //     revert OneOfRedeemTokensAndRedeemAmountMustBeZero();
  //   }
  // }

  /**
   * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
   * @param cToken The market to verify the borrow against
   * @param borrower The account which would borrow the asset
   * @param borrowAmount The amount of underlying the account would borrow
   */
  function borrowAllowed(address cToken, address borrower, uint256 borrowAmount) external {
    // Pausing is a very serious situation - we revert to sound the alarms
    if (protocolPaused) {
      revert ProtocolIsPaused();
    }
    if (borrowGuardianPaused[cToken]) {
      revert BorrowPaused();
    }

    require(markets[cToken].isListed, MARKET_NOT_LISTED);

    if (!markets[cToken].accountMembership[borrower]) {
      // only cTokens may call borrowAllowed if borrower not in market
      if (msg.sender != cToken) {
        revert OnlyCToken();
      }

      // attempt to add borrower to the market
      addToMarketInternal(msg.sender, borrower);

      // it should be impossible to break the important invariant
      assert(markets[cToken].accountMembership[borrower]);
    }

    if (oracle.getUnderlyingPrice(cToken) <= 0) {
      revert PriceError();
    }

    //uint borrowCap = borrowCaps[cToken];
    uint256 borrowCap = borrowCaps[cToken];
    // Borrow cap of 0 corresponds to unlimited borrowing
    if (borrowCap != 0) {
      uint256 totalBorrows = ICToken(cToken).totalBorrows();
      uint256 nextTotalBorrows = totalBorrows + borrowAmount;
      if (nextTotalBorrows >= borrowCap) {
        revert BorrowCapReached();
      }
    }

    // check MinSuBorrowValue for csuToken
    if (!ICToken(cToken).isCToken()) {
      uint256 borrowBalance = ICToken(cToken).borrowBalanceStored(msg.sender);
      uint256 priceMantissa = getUnderlyingPriceNormalized(cToken);
      uint256 borrowVal = (priceMantissa * (borrowBalance + borrowAmount)) / expScale;
      if (minSuBorrowValue > 0 && borrowVal < minSuBorrowValue) {
        revert BorrowValueMustBeLargerThanThreshold(minSuBorrowValue);
      }
    }

    (, uint256 shortfall) = accountLiquidity.getHypotheticalAccountLiquidity(borrower, cToken, 0, borrowAmount);
    if (shortfall > 0) {
      revert InsufficientCollateral();
    }

    // TODO: temporarily comment out for less gas usage
    // Keep the flywheel moving
    // Exp memory borrowIndex = Exp({mantissa: ICToken(cToken).borrowIndex()});
    // compLogic.updateCompBorrowIndex(cToken, borrowIndex);
    // compLogic.distributeBorrowerComp(cToken, borrower, borrowIndex);
  }

  /**
   * underlying price for specific ctoken (unit of 1e36)
   */
  function getUnderlyingPriceNormalized(address cToken) public view returns (uint256) {
    uint256 priceMantissa = oracle.getUnderlyingPrice(cToken);
    if (priceMantissa <= 0) {
      revert PriceError();
    }
    uint decimals = ICToken(cToken).decimals();
    if (decimals < 18) {
      priceMantissa = priceMantissa * (10 ** (18 - decimals));
    }
    return priceMantissa;
  }

  /**
   * @notice Checks if the account should be allowed to repay a borrow in the given market
   * @param cToken The market to verify the repay against
   * @param payer The account which would repay the asset
   * @param borrower The account which would borrowed the asset
   * @param repayAmount The amount of the underlying asset the account would repay
   */
  function repayBorrowAllowed(address cToken, address payer, address borrower, uint256 repayAmount) external {
    // Shh - currently unused: repayAmount;

    require(markets[cToken].isListed, MARKET_NOT_LISTED);

    // TODO: temporarily comment out for less gas usage
    // Keep the flywheel moving
    // Exp memory borrowIndex = Exp({mantissa: ICToken(cToken).borrowIndex()});
    // compLogic.updateCompBorrowIndex(cToken, borrowIndex);
    // compLogic.distributeBorrowerComp(cToken, borrower, borrowIndex);
  }

  /**
   * @notice Checks if the seizing of assets should be allowed to occur
   * @param cTokenCollateral Asset which was used as collateral and will be seized
   * @param cTokenBorrowed Asset which was borrowed by the borrower
   * @param liquidator The address repaying the borrow and seizing the collateral
   * @param borrower The address of the borrower
   * @param seizeTokens The number of collateral tokens to seize
   */
  function seizeAllowed(
    address cTokenCollateral,
    address cTokenBorrowed,
    address liquidator,
    address borrower,
    uint256 seizeTokens
  ) external {
    // Pausing is a very serious situation - we revert to sound the alarms
    if (protocolPaused) {
      revert ProtocolIsPaused();
    }
    if (seizeGuardianPaused) {
      revert SeizePaused();
    }

    // Shh - currently unused: seizeTokens;

    require(markets[cTokenCollateral].isListed && markets[cTokenBorrowed].isListed, MARKET_NOT_LISTED);

    if (ICToken(cTokenCollateral).comptroller() != ICToken(cTokenBorrowed).comptroller()) {
      revert ComptrollerMismatch();
    }

    // TODO: temporarily comment out for less gas usage
    // Keep the flywheel moving
    // compLogic.updateCompSupplyIndex(cTokenCollateral);
    // compLogic.distributeSupplierComp(cTokenCollateral, borrower);
    // compLogic.distributeSupplierComp(cTokenCollateral, liquidator);
  }

  /**
   * @notice Checks if the account should be allowed to transfer tokens in the given market
   * @param cToken The market to verify the transfer against
   * @param src The account which sources the tokens
   * @param dst The account which receives the tokens
   * @param transferTokens The number of cTokens to transfer
   */
  function transferAllowed(address cToken, address src, address dst, uint256 transferTokens) external {
    // Pausing is a very serious situation - we revert to sound the alarms
    if (protocolPaused) {
      revert ProtocolIsPaused();
    }
    if (transferGuardianPaused) {
      revert TransferPaused();
    }

    // Currently the only consideration is whether or not
    //  the src is allowed to redeem this many tokens
    redeemAllowedInternal(cToken, src, transferTokens);

    // TODO: temporarily comment out for less gas usage
    // Keep the flywheel moving
    // compLogic.updateCompSupplyIndex(cToken);
    // compLogic.distributeSupplierComp(cToken, src);
    // compLogic.distributeSupplierComp(cToken, dst);
  }

  /**
   * @notice Checks if the liquidation should be allowed to occur
   * @param cTokenCollateral Asset which was used as collateral and will be seized
   * @param liquidator The address repaying the borrow and seizing the collateral
   * @param borrower The address of the borrower
   * @param repayAmount The amount of underlying being repaid
   */
  function liquidateBorrowAllowed(
    address cTokenBorrowed,
    address cTokenCollateral,
    address liquidator,
    address borrower,
    uint256 repayAmount
  ) public view {
    // Shh - currently unused:
    liquidator;
    if (!markets[cTokenBorrowed].isListed || !markets[cTokenCollateral].isListed) {
      revert MarketNotListed();
    }

    uint256 borrowBalance = ICToken(cTokenBorrowed).borrowBalanceStored(borrower);

    if (block.timestamp - minWaitBeforeLiquidatable <= lastBorrowedAt[borrower]) {
      revert NotLiquidatableYet();
    }
    /* allow accounts to be liquidated if the market is deprecated */
    if (ICToken(cTokenBorrowed).isDeprecated()) {
      if (borrowBalance < repayAmount) {
        revert TooMuchRepay();
      }
    } else {
      /* The borrower must have shortfall in order to be liquidatable */
      (, uint256 shortfall) = accountLiquidity.getHypotheticalAccountLiquidity(borrower, cTokenBorrowed, 0, 0);

      if (shortfall <= 0) {
        revert InsufficientShortfall();
      }
      uint256 priceMantissa = getUnderlyingPriceNormalized(cTokenBorrowed);
      /* The liquidator may not repay more than what is allowed by the closeFactor */
      uint256 maxClose = (closeFactorMantissa * borrowBalance) / expScale;
      uint256 maxCloseValue = (priceMantissa * maxClose) / expScale;
      if (maxCloseValue < minCloseValue) {
        if (repayAmount > borrowBalance) {
          revert TooMuchRepay();
        }
      } else {
        if (repayAmount > maxClose) {
          revert TooMuchRepay();
        }
      }
    }
  }

  /**
   * @notice Validates borrow and reverts on rejection. May emit logs.
   * @param borrower The address borrowing the underlying
   * @param borrowAmount The amount of the underlying asset requested to borrow
   */
  function borrowVerify(address borrower, uint256 borrowAmount) external {
    require(isListed(msg.sender), MARKET_NOT_LISTED);

    // Shh - currently unused
    // address cToken = msg.sender;
    borrower;
    borrowAmount;
    // redemptionManager.updateSortedBorrows(cToken, borrower);

    lastBorrowedAt[borrower] = uint48(block.timestamp);
  }

  /**
   * @notice Validates repayBorrow and reverts on rejection. May emit logs.
   * @param cToken Asset being repaid
   * @param payer The address repaying the borrow
   * @param borrower The address of the borrower
   * @param actualRepayAmount The amount of underlying being repaid
   */
  // function repayBorrowVerify(
  //   address cToken,
  //   address payer,
  //   address borrower,
  //   uint256 actualRepayAmount,
  //   uint256 borrowerIndex
  // ) external onlyListedCToken {
  //   // Shh - currently unused
  //   cToken;
  //   payer;
  //   borrower;
  //   actualRepayAmount;
  //   borrowerIndex;

  //   redemptionManager.updateSortedBorrows(cToken, borrower);
  // }

  /**
   * @notice Validates seize and reverts on rejection. May emit logs.
   * @param cTokenCollateral Asset which was used as collateral and will be seized
   * @param cTokenBorrowed Asset which was borrowed by the borrower
   * @param liquidator The address repaying the borrow and seizing the collateral
   * @param borrower The address of the borrower
   * @param seizeTokens The number of collateral tokens to seize
   */
  // function seizeVerify(
  //   address cTokenCollateral,
  //   address cTokenBorrowed,
  //   address liquidator,
  //   address borrower,
  //   uint256 seizeTokens
  // ) external onlyListedCToken {
  //   // Shh - currently unused
  //   cTokenCollateral;
  //   cTokenBorrowed;
  //   liquidator;
  //   borrower;
  //   seizeTokens;

  //   redemptionManager.updateSortedBorrows(cTokenBorrowed, borrower);
  // }
}
