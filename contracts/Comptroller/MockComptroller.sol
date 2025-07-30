// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import './ComptrollerStorage.sol';
import '../Interfaces/ICTokenExternal.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '../SumerErrors.sol';

/**
 * @title Compound's Comptroller Contract
 * @author Compound
 */
contract MockComptroller is AccessControl, ComptrollerStorage, SumerErrors {
  /// @notice Emitted when an admin supports a market
  event MarketListed(address cToken);

  event MarketUnlisted(address cToken);

  /// @notice Emitted when an account enters a market
  event MarketEntered(address cToken, address account);

  /// @notice Emitted when an account exits a market
  event MarketExited(address cToken, address account);

  /// @notice Emitted when liquidation incentive is changed by admin
  event NewLiquidationIncentive(uint16 heteroPercent, uint64 homoPercent, uint64 sutokenPercent);

  event NewDependencies(address compLogic, address redemptionManager);

  event NewPause(address ctoken, bool mintPaused, bool borrowPaused, bool transferPaused, bool seizePaused);

  event NewTimelock(address timelock);

  event NewPriceOracle(address priceOracle);

  /// @notice Emitted when global config is changed
  event NewGlobalConfig(
    uint16 closeFactorPercent,
    uint32 minCloseValue,
    uint32 minSuBorrowValue,
    uint32 minWaitBeforeLiquidatable,
    uint8 largestGroupId
  );

  /// @notice Emitted when market for a cToken is changed
  event NewCap(address indexed cToken, uint120 borrowCap, uint120 supplyCap);

  /// @notice Emitted when pause guardian is changed
  event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

  event UpdateAssetGroup(
    uint8 indexed groupId,
    uint16 intraCRatePercent,
    uint16 intraMintRatePercent,
    uint16 intraSuRatePercent,
    uint16 interCRatePercent,
    uint16 interSuRatePercent,
    bool isNewGroup
  );

  event RemoveAssetGroup(uint8 indexed groupId);

  constructor(address _admin, address _oracle) {
    _setupRole(DEFAULT_ADMIN_ROLE, _admin);

    oracle = IPriceOracle(_oracle);
    emit NewPriceOracle(address(oracle));
  }

  /////////////////////////////////////////////////////////
  // Modifiers
  /////////////////////////////////////////////////////////
  /// @notice Checks if the provided address is nonzero, reverts otherwise
  /// @param address_ Address to check
  /// @custom:error ZeroAddressNotAllowed is thrown if the provided address is a zero address
  modifier ensureNonzeroAddress(address address_) {
    if (address_ == address(0)) {
      revert ZeroAddressNotAllowed();
    }
    _;
  }

  modifier onlyListedCToken(address cToken) {
    if (!isListed(cToken)) {
      revert OnlyListedCToken();
    }
    _;
  }

  modifier onlyAdminOrPauser() {
    if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(PAUSER_ROLE, msg.sender)) {
      revert OnlyAdminOrPauser();
    }
    _;
  }

  /////////////////////////////////////////////////////////
  // Market Function
  /////////////////////////////////////////////////////////
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
  function checkMembership(address account, address cToken) internal view returns (bool) {
    return markets[cToken].accountMembership[account];
  }

  function isListed(address asset) public view returns (bool) {
    return markets[asset].isListed;
  }

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
   */
  function enterMarketsFor(address owner, address[] memory cTokens) public {
    uint256 len = cTokens.length;

    for (uint256 i = 0; i < len; ++i) {
      address cToken = cTokens[i];
      addToMarketInternal(cToken, owner);
    }
  }

  /**
   * @notice Add the market to the borrower's "assets in" for liquidity calculations
   * @param cToken The market to enter
   * @param borrower The address of the account to modify
   */
  function addToMarketInternal(address cToken, address borrower) internal onlyListedCToken(cToken) {
    Market storage marketToJoin = markets[cToken];

    if (marketToJoin.accountMembership[borrower]) {
      // already joined
      return;
    }

    if (
      marketConfig[cToken].mintPaused ||
      marketConfig[cToken].borrowPaused ||
      marketConfig[cToken].transferPaused ||
      marketConfig[cToken].seizePaused
    ) {
      revert CantEnterPausedMarket();
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

    return;
  }

  /**
   * @notice Removes asset from sender's account liquidity calculation
   * @dev Sender must not have an outstanding borrow balance in the asset,
   *  or be providing necessary collateral for an outstanding borrow.
   * @param cTokenAddress The address of the asset to be removed
   */
  function exitMarketFor(address owner, address cTokenAddress) external {
    address cToken = cTokenAddress;
    /* Get sender tokensHeld and amountOwed underlying from the cToken */
    (uint256 tokensHeld, uint256 amountOwed, , ) = ICToken(cToken).getAccountSnapshot(owner);

    /* Fail if the sender has a borrow balance */
    if (amountOwed != 0) {
      revert CantExitMarketWithNonZeroBorrowBalance();
    }
    /* Fail if the sender is not permitted to redeem all of their tokens */
    redeemAllowedInternal(cTokenAddress, owner, tokensHeld);

    _exitMarketInternal(owner, cTokenAddress);
  }

  function _exitMarketInternal(address user, address cTokenAddress) internal {
    Market storage marketToExit = markets[cTokenAddress];

    /* Return true if the sender is not already ‘in’ the market */
    if (!marketToExit.accountMembership[user]) {
      return;
    }

    /* Set cToken account membership to false */
    delete marketToExit.accountMembership[user];

    /* Delete cToken from the account’s list of assets */
    // load into memory for faster iteration
    address[] memory userAssetList = accountAssets[user];
    uint256 len = userAssetList.length;
    uint256 assetIndex = len;
    for (uint256 i = 0; i < len; ++i) {
      if (userAssetList[i] == cTokenAddress) {
        assetIndex = i;
        break;
      }
    }

    // We *must* have found the asset in the list or our redundant data structure is broken
    assert(assetIndex < len);

    // copy last item in list to location of item to be removed, reduce length by 1
    address[] storage storedList = accountAssets[user];
    storedList[assetIndex] = storedList[storedList.length - 1];
    storedList.pop();

    // remove the same
    //exitEqualAssetGroupInternal(cTokenAddress, msg.sender);

    emit MarketExited(cTokenAddress, user);
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
   */
  function _supportMarket(
    address cToken,
    uint8 groupId,
    uint120 borrowCap,
    uint120 supplyCap
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (markets[cToken].isListed) {
      revert MarketAlreadyListed();
    }
    if (groupId <= 0) {
      revert InvalidGroupId();
    }

    // ICToken(cToken).isCToken();
    ICToken(cToken).isCToken(); // Sanity check to make sure its really a address

    // Note that isComped is not in active use anymore
    // markets[cToken] = Market({isListed: true, isComped: false, assetGroupId: groupId});
    Market storage market = markets[cToken];
    market.isListed = true;
    market.assetGroupId = groupId;

    _addMarketInternal(cToken);
    _initializeMarket(cToken);

    emit MarketListed(cToken);

    marketConfig[cToken].borrowCap = borrowCap;
    marketConfig[cToken].supplyCap = supplyCap;
    emit NewCap(cToken, borrowCap, supplyCap);
  }

  /**
   * @notice Add the market to the markets mapping and set it as listed
   * @dev Admin function to set isListed and add support for the market
   * @param cToken The address of the market (token) to list
   */
  function _unlistMarket(address cToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (!markets[cToken].isListed) {
      revert MarketAlreadyUnlisted();
    }

    if (
      !(marketConfig[cToken].mintPaused &&
        marketConfig[cToken].borrowPaused &&
        marketConfig[cToken].transferPaused &&
        marketConfig[cToken].seizePaused)
    ) {
      revert OnlyPausedMarketCanBeUnlisted();
    }

    // only allow unlist current market if its total borrow usd value is lte 1
    uint256 usdValue = (getUnderlyingPriceNormalized(cToken) * ICToken(cToken).totalBorrows()) / 1e36;
    if (usdValue > 1) {
      revert MarketNotEmpty();
    }
    // if (ICToken(cToken).totalBorrows() != 0) {
    //   revert TotalBorrowsNotZero();
    // }

    if (ICToken(cToken).totalSupply() != 0) {
      revert TotalSupplyNotZero();
    }

    // Note that isComped is not in active use anymore
    // markets[cToken] = Market({isListed: true, isComped: false, assetGroupId: groupId});
    delete markets[cToken];

    uint len = allMarkets.length;
    uint index = len;
    for (uint i = 0; i < len; ++i) {
      if (allMarkets[i] == cToken) {
        index = i;
        break;
      }
    }
    assert(index < len);
    allMarkets[index] = allMarkets[len - 1];
    allMarkets.pop();

    emit MarketUnlisted(cToken);

    // keep marketConfig here so that paused information is not lost
    // if the market is listed back again, it's still paused
    marketConfig[cToken].supplyCap = 0;
    marketConfig[cToken].borrowCap = 0;
  }

  // Please use this with caution, because changing groupId of assets will affects liquidity/shortfall of accounts
  // and will make some previously healthy accounts underwater
  function _changeGroupIdForAsset(
    address cToken,
    uint8 newGroupId
  ) external onlyRole(DEFAULT_ADMIN_ROLE) onlyListedCToken(cToken) {
    if (newGroupId == 0) {
      revert InvalidGroupId();
    }
    CompactAssetGroup memory g = assetGroup[newGroupId];
    if (g.groupId != newGroupId) {
      revert InvalidGroupId();
    }
    markets[cToken].assetGroupId = newGroupId;
  }

  function _initializeMarket(address cToken) internal {
    if (block.number >= 2 ** 32) {
      revert InvalidBlockNumber();
    }
    uint32 blockNumber = uint32(block.number);
  }

  /////////////////////////////////////////////////////////
  // Setters
  /////////////////////////////////////////////////////////
  /**
   * @notice Return the address of the COMP token
   * @param _governanceToken The address of COMP(governance token)
   */
  function _setGovTokenAddress(
    address _governanceToken
  ) external onlyRole(DEFAULT_ADMIN_ROLE) ensureNonzeroAddress(_governanceToken) {
    governanceToken = _governanceToken;
  }

  function _setTimelock(address _timelock) external onlyRole(DEFAULT_ADMIN_ROLE) ensureNonzeroAddress(_timelock) {
    timelock = _timelock;
    emit NewTimelock(_timelock);
  }

  /**
   * @notice Sets a new price oracle for the comptroller
   * @dev Admin function to set a new price oracle
   */
  function _setPriceOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) ensureNonzeroAddress(_oracle) {
    oracle = IPriceOracle(_oracle);
    emit NewPriceOracle(_oracle);
  }

  function _setInterMintAllowed(bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
    interMintAllowed = allowed;
  }

  function _setGlobalConfig(GlobalConfig calldata globalConfig_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    // Save current value for use in log
    uint8 largestGroupId = globalConfig.largestGroupId;
    globalConfig = globalConfig_;
    globalConfig.largestGroupId = largestGroupId;
    emit NewGlobalConfig(
      globalConfig_.closeFactorPercent,
      globalConfig_.minCloseValue,
      globalConfig_.minSuBorrowValue,
      globalConfig_.minWaitBeforeLiquidatable,
      largestGroupId
    );
  }

  function _setLargestGroupId(uint8 largestGroupId) external onlyRole(DEFAULT_ADMIN_ROLE) {
    globalConfig.largestGroupId = largestGroupId;
  }
  /**
   * @notice Sets liquidationIncentive
   * @dev Admin function to set liquidationIncentive
   * @param liquidationIncentive_ New liquidationIncentive scaled by 1e18 for hetero/homo/sutoken assets
   */
  function _setLiquidationIncentive(
    LiquidationIncentive calldata liquidationIncentive_
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    // Save current value for use in log
    liquidationIncentive = liquidationIncentive_;
    // Emit event with old incentive, new incentive
    emit NewLiquidationIncentive(
      liquidationIncentive_.heteroPercent,
      liquidationIncentive_.homoPercent,
      liquidationIncentive_.sutokenPercent
    );
  }

  /**
   * @notice Set the given borrow caps for the given cToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
   * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
   * @param cTokens The addresses of the markets (tokens) to change the borrow caps for
   * @param borrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
   * @param supplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.

   */
  function _setCaps(
    address[] calldata cTokens,
    uint120[] calldata borrowCaps,
    uint120[] calldata supplyCaps
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 numMarkets = cTokens.length;
    if (numMarkets == 0 || numMarkets != borrowCaps.length || numMarkets != supplyCaps.length) {
      revert InvalidInput();
    }

    for (uint256 i = 0; i < numMarkets; i++) {
      marketConfig[cTokens[i]].borrowCap = borrowCaps[i];
      marketConfig[cTokens[i]].supplyCap = supplyCaps[i];
      emit NewCap(cTokens[i], borrowCaps[i], supplyCaps[i]);
    }
  }

  /////////////////////////////////////////////////////////
  // Asset Group related
  /////////////////////////////////////////////////////////
  function setAssetGroup(
    uint8 groupId,
    uint16 intraCRatePercent, // ctoken collateral rate for intra group ctoken liability
    uint16 intraMintRatePercent, // ctoken collateral rate for intra group sutoken liability
    uint16 intraSuRatePercent, // sutoken collateral rate for intra group ctoken liability
    uint16 interCRatePercent, // ctoken collateral rate for inter group ctoken/sutoken liability
    uint16 interSuRatePercent // sutoken collateral rate for inter group ctoken/sutoken liability
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    bool groupAdded = assetGroup[groupId].groupId == 0;

    assetGroup[groupId] = CompactAssetGroup(
      groupId,
      intraCRatePercent,
      intraMintRatePercent,
      intraSuRatePercent,
      interCRatePercent,
      interSuRatePercent
    );
    emit UpdateAssetGroup(
      groupId,
      intraCRatePercent,
      intraMintRatePercent,
      intraSuRatePercent,
      interCRatePercent,
      interSuRatePercent,
      groupAdded
    );
    if (groupId > globalConfig.largestGroupId) {
      globalConfig.largestGroupId = groupId;
    }
  }

  function removeAssetGroup(uint8 groupId) external onlyRole(DEFAULT_ADMIN_ROLE) {
    delete assetGroup[groupId];
    emit RemoveAssetGroup(groupId);
  }

  // function cleanAssetGroup() external onlyRole(DEFAULT_ADMIN_ROLE) {
  //   for (uint8 i = 0; i < globalConfig.largestGroupId; i++) {
  //     delete assetGroup[i];
  //   }

  //   globalConfig.largestGroupId = 0;
  // }

  /////////////////////////////////////////////////////////
  // Pause related
  /////////////////////////////////////////////////////////
  /**
   * @notice Admin function to change the Pause Guardian
   * @param newPauseGuardian The address of the new Pause Guardian
   */
  function _setPauseGuardian(
    address newPauseGuardian
  ) external onlyRole(DEFAULT_ADMIN_ROLE) ensureNonzeroAddress(newPauseGuardian) {
    // Save current value for inclusion in log
    address oldPauseGuardian = pauseGuardian;
    revokeRole(PAUSER_ROLE, oldPauseGuardian);

    // Store pauseGuardian with value newPauseGuardian
    pauseGuardian = newPauseGuardian;
    grantRole(PAUSER_ROLE, newPauseGuardian);

    // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
    emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);
  }

  // Pause functions
  function _pause(
    address cToken,
    bool mintPaused,
    bool borrowPaused,
    bool transferPaused,
    bool seizePaused
  ) external onlyAdminOrPauser {
    marketConfig[cToken].mintPaused = mintPaused;
    marketConfig[cToken].borrowPaused = borrowPaused;
    marketConfig[cToken].transferPaused = transferPaused;
    marketConfig[cToken].seizePaused = seizePaused;
    emit NewPause(address(cToken), mintPaused, borrowPaused, transferPaused, seizePaused);
  }

  /////////////////////////////////////////////////////////
  // Policy Hooks
  /////////////////////////////////////////////////////////
  /**
   * @notice Checks if the account should be allowed to mint tokens in the given market
   * @param cToken The market to verify the mint against
   * @param minter The account which would get the minted tokens
   * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
   */
  function mintAllowed(address cToken, address minter, uint256 mintAmount, uint256 exchangeRate) external {
    if (exchangeRate > 5 * expScale) {
      revert InvalidExchangeRate();
    }
    // Pausing is a very serious situation - we revert to sound the alarms
    if (marketConfig[cToken].mintPaused) {
      revert MintPaused();
    }

    // Shh - currently unused: minter; mintAmount;

    /* Get minter's cToken balance*/
    (uint256 tokensHeld, uint256 amountOwed, , ) = ICToken(cToken).getAccountSnapshot(minter);

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

    uint256 exchangeRateMantissa = ICToken(cToken).exchangeRateStored();
    if (
      (ICToken(cToken).totalSupply() * exchangeRateMantissa) / expScale + mintAmount > marketConfig[cToken].supplyCap
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
  function redeemAllowed(address cToken, address redeemer, uint256 redeemTokens, uint256 exchangeRate) external {
    if (exchangeRate > 5 * expScale) {
      revert InvalidExchangeRate();
    }
    redeemAllowedInternal(cToken, redeemer, redeemTokens);

    // TODO: temporarily comment out for less gas usage
    // Keep the flywheel moving
    // compLogic.updateCompSupplyIndex(cToken);
    // compLogic.distributeSupplierComp(cToken, redeemer);
  }

  function redeemAllowedInternal(address cToken, address redeemer, uint256 redeemTokens) internal view {
    /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
    if (!markets[cToken].accountMembership[redeemer]) {
      return;
    }

    /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
    (, uint256 shortfall) = getHypotheticalAccountLiquidity(redeemer, cToken, redeemTokens, 0);
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
  function redeemVerify(address cToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens) external {
    // Shh - currently unused: cToken; redeemer;

    // Require tokens is zero or amount is also zero
    if (redeemTokens == 0 && redeemAmount > 0) {
      revert InvalidRedeem();
    }

    (uint256 tokensHeld, uint256 amountOwed, , ) = ICToken(cToken).getAccountSnapshot(redeemer);

    if (tokensHeld == 0 && amountOwed == 0) {
      _exitMarketInternal(redeemer, cToken);
    }
  }

  /**
   * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
   * @param cToken The market to verify the borrow against
   * @param borrower The account which would borrow the asset
   * @param borrowAmount The amount of underlying the account would borrow
   */
  function borrowAllowed(address cToken, address borrower, uint256 borrowAmount) external {
    // Pausing is a very serious situation - we revert to sound the alarms
    if (marketConfig[cToken].borrowPaused) {
      revert BorrowPaused();
    }

    for (uint256 i = 0; i < accountAssets[borrower].length; ++i) {
      address asset = accountAssets[borrower][i];

      if (!markets[asset].isListed) {
        // unlisted market
        (uint256 tokensHeld, uint256 amountOwed, , ) = ICToken(asset).getAccountSnapshot(borrower);

        if (tokensHeld == 0 && amountOwed == 0) {
          _exitMarketInternal(borrower, asset);
        } else {
          revert MarketNotListed();
        }
      } else if (marketConfig[asset].borrowPaused) {
        revert MarketPaused();
      }
    }

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

    //uint borrowCap = borrowCaps[cToken];
    if (ICToken(cToken).totalBorrows() + borrowAmount > marketConfig[cToken].borrowCap) {
      revert BorrowCapReached();
    }

    // check MinSuBorrowValue for csuToken
    // if (!ICToken(cToken).isCToken()) {
    //   uint256 borrowBalance = ICToken(cToken).borrowBalanceStored(msg.sender);
    //   uint256 priceMantissa = getUnderlyingPriceNormalized(cToken);
    //   uint256 borrowVal = (priceMantissa * (borrowBalance + borrowAmount)) / expScale/ expScale;
    //   if (minSuBorrowValue > 0 && borrowVal < minSuBorrowValue) {
    //     revert BorrowValueMustBeLargerThanThreshold(minSuBorrowValue);
    //   }
    // }

    (, uint256 shortfall) = getHypotheticalAccountLiquidity(borrower, cToken, 0, borrowAmount);
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
    if (!isListed(cToken)) {
      revert MarketNotListed();
    }
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
    // TODO: temporarily comment out for less gas usage
    // Keep the flywheel moving
    // Exp memory borrowIndex = Exp({mantissa: ICToken(cToken).borrowIndex()});
    // compLogic.updateCompBorrowIndex(cToken, borrowIndex);
    // compLogic.distributeBorrowerComp(cToken, borrower, borrowIndex);
  }

  /**
   * @notice Validates repayBorrow and reverts on rejection. May emit logs.
   * @param cToken Asset being repaid
   * @param payer The address repaying the borrow
   * @param borrower The address of the borrower
   * @param actualRepayAmount The amount of underlying being repaid
   */
  function repayBorrowVerify(
    address cToken,
    address payer,
    address borrower,
    uint actualRepayAmount,
    uint borrowIndex
  ) external {
    // Shh - currently unused
    payer;
    borrower;
    actualRepayAmount;
    borrowIndex;

    (uint256 tokensHeld, uint256 amountOwed, , ) = ICToken(cToken).getAccountSnapshot(borrower);

    if (tokensHeld == 0 && amountOwed == 0) {
      _exitMarketInternal(borrower, cToken);
    }
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
    if (marketConfig[cTokenCollateral].seizePaused) {
      revert SeizePaused();
    }

    // Shh - currently unused: seizeTokens;
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
    if (marketConfig[cToken].transferPaused) {
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

    if (!ICToken(cTokenBorrowed).isCToken() && ICToken(cTokenCollateral).isCToken() && !interMintAllowed) {
      revert InterMintNotAllowed();
    }

    uint256 borrowBalance = ICToken(cTokenBorrowed).borrowBalanceStored(borrower);

    if (block.timestamp - globalConfig.minWaitBeforeLiquidatable <= lastBorrowedAt[borrower]) {
      revert NotLiquidatableYet();
    }
    /* allow accounts to be liquidated if the market is deprecated */
    /* The borrower must have shortfall in order to be liquidatable */
    (, uint256 shortfall) = getHypotheticalAccountLiquidity(borrower, cTokenBorrowed, 0, 0);

    if (shortfall <= 0) {
      revert InsufficientShortfall();
    }
    uint256 priceMantissa = getUnderlyingPriceNormalized(cTokenBorrowed);
    /* The liquidator may not repay more than what is allowed by the closeFactor */
    uint256 maxClose = (uint256(globalConfig.closeFactorPercent) * percentScale * borrowBalance) / expScale;
    uint256 maxCloseValue = (priceMantissa * maxClose) / expScale / expScale;
    if (maxCloseValue < globalConfig.minCloseValue) {
      if (repayAmount > borrowBalance) {
        revert TooMuchRepay();
      }
    } else {
      if (repayAmount > maxClose) {
        revert TooMuchRepay();
      }
    }
  }

  /**
   * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
   * @param cTokenBorrowed Asset which was borrowed by the borrower
   * @param cTokenCollateral Asset which was used as collateral and will be seized
   * @param liquidator The address repaying the borrow and seizing the collateral
   * @param borrower The address of the borrower
   * @param actualRepayAmount The amount of underlying being repaid
   */
  function liquidateBorrowVerify(
    address cTokenBorrowed,
    address cTokenCollateral,
    address liquidator,
    address borrower,
    uint actualRepayAmount,
    uint seizeTokens
  ) external {
    // Shh - currently unused
    cTokenCollateral;
    liquidator;
    borrower;
    actualRepayAmount;
    seizeTokens;

    (uint256 tokensHeld, uint256 amountOwed, , ) = ICToken(cTokenBorrowed).getAccountSnapshot(borrower);

    if (tokensHeld == 0 && amountOwed == 0) {
      _exitMarketInternal(borrower, cTokenBorrowed);
    }
  }
  /**
   * @notice Validates borrow and reverts on rejection. May emit logs.
   * @param borrower The address borrowing the underlying
   * @param borrowAmount The amount of the underlying asset requested to borrow
   */
  function borrowVerify(address borrower, uint256 borrowAmount) external {
    // Shh - currently unused
    // address cToken = msg.sender;
    borrower;
    borrowAmount;
    // redemptionManager.updateSortedBorrows(cToken, borrower);

    lastBorrowedAt[borrower] = uint48(block.timestamp);
  }
  function getHypoStep1(
    address account,
    address cTokenModify,
    uint256 redeemTokens,
    uint256 borrowAmount
  ) public view returns (GroupVar[] memory) {
    uint256 assetsGroupNum = globalConfig.largestGroupId + 1;
    GroupVar[] memory groupVars = new GroupVar[](assetsGroupNum);

    // For each asset the account is in
    address[] memory assets = accountAssets[account];

    // loop through tokens to add deposit/borrow for ctoken/sutoken in each group
    for (uint256 i = 0; i < assets.length; ++i) {
      address asset = assets[i];
      uint256 depositVal = 0;
      uint256 borrowVal = 0;
      if (!markets[asset].isListed) {
        continue;
      }

      uint8 assetGroupId = markets[asset].assetGroupId;
      if (groupVars[assetGroupId].groupId == 0 && assetGroupId != 0) {
        CompactAssetGroup memory g = assetGroup[assetGroupId];
        groupVars[assetGroupId] = GroupVar(
          g.groupId,
          0,
          0,
          0,
          0,
          uint256(g.intraCRatePercent) * percentScale,
          uint256(g.intraMintRatePercent) * percentScale,
          uint256(g.intraSuRatePercent) * percentScale,
          uint256(g.interCRatePercent) * percentScale,
          uint256(g.interSuRatePercent) * percentScale
        );
      }

      (
        uint256 depositBalance,
        uint256 borrowBalance,
        uint256 exchangeRateMantissa,
        uint256 discountRateMantissa
      ) = ICToken(asset).getAccountSnapshot(account);

      // skip the calculation to save gas
      if (asset != cTokenModify && depositBalance == 0 && borrowBalance == 0) {
        continue;
      }

      // Get price of asset
      // normalize price for asset with unit of 1e(36-token decimal)
      uint256 oraclePriceMantissa = getUnderlyingPriceNormalized(asset);

      // Pre-compute a conversion factor from tokens -> USD (normalized price value)
      // tokensToDenom = oraclePrice * exchangeRate * discourntRate
      uint256 tokensToDenom = (((oraclePriceMantissa * exchangeRateMantissa) / expScale) * discountRateMantissa) /
        expScale;

      depositVal += (tokensToDenom * depositBalance) / expScale;
      borrowVal += (oraclePriceMantissa * borrowBalance) / expScale;
      if (asset == cTokenModify) {
        uint256 redeemVal = (tokensToDenom * redeemTokens) / expScale;
        if (redeemVal <= depositVal) {
          // if redeemedVal <= depositVal, absorb it with deposits
          depositVal = depositVal - redeemVal;
          redeemVal = 0;
        } else {
          // if redeemVal > depositVal
          redeemVal = redeemVal - depositVal;
          borrowVal = borrowVal + redeemVal;
          depositVal = 0;
        }

        borrowVal += (oraclePriceMantissa * borrowAmount) / expScale;
      }

      if (ICToken(asset).isCToken()) {
        groupVars[assetGroupId].cDepositVal += depositVal;
        groupVars[assetGroupId].cBorrowVal += borrowVal;
      } else {
        groupVars[assetGroupId].suDepositVal += depositVal;
        groupVars[assetGroupId].suBorrowVal += borrowVal;
      }
    }
    return groupVars;
    // end of loop in assets
  }

  function getHypoStep2(
    address account,
    address cTokenModify,
    uint256 redeemTokens,
    uint256 borrowAmount
  ) public view returns (uint256, uint256, uint256, uint256, GroupVar memory) {
    uint256 assetsGroupNum = globalConfig.largestGroupId + 1;
    GroupVar[] memory groupVars = getHypoStep1(account, cTokenModify, redeemTokens, borrowAmount);
    // loop in groups to calculate accumulated collateral/liability for two types:
    // inter-group and intra-group for target token
    uint8 targetGroupId = markets[cTokenModify].assetGroupId;
    GroupVar memory targetGroup;
    uint256 sumLiquidity = 0;
    uint256 sumBorrowPlusEffects = 0;
    uint256 sumInterCBorrowVal = 0;
    uint256 sumInterSuBorrowVal = 0;

    for (uint8 i = 0; i < assetsGroupNum; ++i) {
      if (groupVars[i].groupId == 0) {
        continue;
      }
      GroupVar memory g = groupVars[i];

      // absorb sutoken loan with ctoken collateral
      if (g.suBorrowVal > 0) {
        (g.cDepositVal, g.suBorrowVal) = absorbLoan(g.cDepositVal, g.suBorrowVal, g.intraMintRate);
      }

      // absorb ctoken loan with ctoken collateral
      if (g.cBorrowVal > 0) {
        (g.cDepositVal, g.cBorrowVal) = absorbLoan(g.cDepositVal, g.cBorrowVal, g.intraCRate);
      }

      // absorb sutoken loan with sutoken collateral
      if (g.suBorrowVal > 0) {
        (g.suDepositVal, g.suBorrowVal) = absorbLoan(g.suDepositVal, g.suBorrowVal, g.intraSuRate);
      }

      // absorb ctoken loan with sutoken collateral
      if (g.cBorrowVal > 0) {
        (g.suDepositVal, g.cBorrowVal) = absorbLoan(g.suDepositVal, g.cBorrowVal, g.intraSuRate);
      }

      // after intra-group collateral-liability match, either asset or debt must be 0
      if (g.cDepositVal + g.suDepositVal != 0 && g.cBorrowVal + g.suBorrowVal != 0) {
        revert EitherAssetOrDebtMustBeZeroInGroup(
          g.groupId,
          g.cDepositVal,
          g.suDepositVal,
          g.cBorrowVal,
          g.suBorrowVal
        );
      }

      if (g.groupId == targetGroupId) {
        targetGroup = g;
      } else {
        sumLiquidity += (g.interCRate * g.cDepositVal) / expScale;
        sumLiquidity += (g.interSuRate * g.suDepositVal) / expScale;
        sumInterCBorrowVal = sumInterCBorrowVal + g.cBorrowVal;
        sumInterSuBorrowVal = sumInterSuBorrowVal + g.suBorrowVal;
      }
    }
    return (sumLiquidity, sumBorrowPlusEffects, sumInterCBorrowVal, sumInterSuBorrowVal, targetGroup);
  }

  /////////////////////////////////////////////////////////
  // Hypothetical Calculation
  /////////////////////////////////////////////////////////
  /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param cTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral cToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
  function getHypotheticalAccountLiquidity(
    address account,
    address cTokenModify,
    uint256 redeemTokens,
    uint256 borrowAmount
  ) public view returns (uint256, uint256) {
    (
      uint256 sumLiquidity,
      uint256 sumBorrowPlusEffects,
      uint256 sumInterCBorrowVal,
      uint256 sumInterSuBorrowVal,
      GroupVar memory targetGroup
    ) = getHypoStep2(account, cTokenModify, redeemTokens, borrowAmount);

    bool targetIsSuToken = (cTokenModify != address(0)) && !ICToken(cTokenModify).isCToken();

    // absorb c-loan with inter group collateral
    (sumLiquidity, sumInterCBorrowVal) = deduct(sumLiquidity, sumInterCBorrowVal);

    // absorb su-loan with inter group collateral only if inter mint is allowed
    if (interMintAllowed) {
      (sumLiquidity, sumInterSuBorrowVal) = deduct(sumLiquidity, sumInterSuBorrowVal);
    }

    // absorb target group c-loan with other group collateral
    (sumLiquidity, targetGroup.cBorrowVal) = deduct(sumLiquidity, targetGroup.cBorrowVal);

    // absorb target group s-loan with other group collateral only if inter mint is allowed
    if (interMintAllowed) {
      (sumLiquidity, targetGroup.suBorrowVal) = deduct(sumLiquidity, targetGroup.suBorrowVal);
    }

    // absorb inter group c-loan with target group c-collateral
    if (sumInterCBorrowVal > 0) {
      (targetGroup.cDepositVal, sumInterCBorrowVal) = absorbLoan(
        targetGroup.cDepositVal,
        sumInterCBorrowVal,
        targetGroup.interCRate
      );
    }

    // absorb inter group c-loan with target group su-collateral
    if (sumInterCBorrowVal > 0) {
      (targetGroup.suDepositVal, sumInterCBorrowVal) = absorbLoan(
        targetGroup.suDepositVal,
        sumInterCBorrowVal,
        targetGroup.interSuRate
      );
    }

    // absorb inter group su-loan only if inter mint allowed
    if (interMintAllowed) {
      // absorb inter group su-loan with target group c-collateral
      if (sumInterSuBorrowVal > 0) {
        (targetGroup.cDepositVal, sumInterSuBorrowVal) = absorbLoan(
          targetGroup.cDepositVal,
          sumInterSuBorrowVal,
          targetGroup.interCRate
        );
      }

      if (sumInterSuBorrowVal > 0) {
        (targetGroup.suDepositVal, sumInterSuBorrowVal) = absorbLoan(
          targetGroup.suDepositVal,
          sumInterSuBorrowVal,
          targetGroup.interSuRate
        );
      }
    }

    sumBorrowPlusEffects = sumInterCBorrowVal + sumInterSuBorrowVal + targetGroup.cBorrowVal + targetGroup.suBorrowVal;
    if (sumBorrowPlusEffects > 0) {
      return (0, sumBorrowPlusEffects);
    }

    if (targetIsSuToken) {
      if (!interMintAllowed) {
        sumLiquidity = 0;
      }
      // if target is sutoken
      // limit = inter-group limit + intra ctoken collateral * intra mint rate
      sumLiquidity += (targetGroup.intraMintRate * targetGroup.cDepositVal) / expScale;
    } else {
      // if target is not sutoken
      // limit = inter-group limit + intra ctoken collateral * intra c rate
      sumLiquidity += (targetGroup.intraCRate * targetGroup.cDepositVal) / expScale;
    }

    // limit = inter-group limit + intra-group ctoken limit + intra sutoken collateral * intra su rate
    sumLiquidity += (targetGroup.intraSuRate * targetGroup.suDepositVal) / expScale;

    return (sumLiquidity, 0);
  }

  function deduct(uint256 collateral, uint256 loan) internal pure returns (uint256, uint256) {
    if (loan == 0) {
      return (collateral, loan);
    }
    if (collateral > loan) {
      collateral -= loan;
      loan = 0;
    } else {
      loan -= collateral;
      collateral = 0;
    }
    return (collateral, loan);
  }

  function absorbLoan(
    uint256 collateralValue,
    uint256 borrowValue,
    uint256 collateralRate
  ) internal pure returns (uint256, uint256) {
    if (collateralRate == 0) {
      return (0, borrowValue);
    }
    uint256 collateralizedLoan = (collateralRate * collateralValue) / expScale;
    uint256 usedCollateral = (borrowValue * expScale) / collateralRate;
    uint256 newCollateralValue = 0;
    uint256 newBorrowValue = 0;
    if (collateralizedLoan > borrowValue) {
      newCollateralValue = collateralValue - usedCollateral;
    } else {
      newBorrowValue = borrowValue - collateralizedLoan;
    }
    return (newCollateralValue, newBorrowValue);
  }

  // version is enabled after V2
  function version() external pure returns (Version) {
    return Version.V3;
  }
}
