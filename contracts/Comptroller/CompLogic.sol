// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import '../Exponential/ExponentialNoErrorNew.sol';
import '../Interfaces/IComptroller.sol';
import '../Interfaces/ICTokenExternal.sol';
import '@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol';
import '../SumerErrors.sol';

contract CompLogic is AccessControlEnumerableUpgradeable, ExponentialNoErrorNew, SumerErrors {
  /// @notice The market's last updated compBorrowIndex or compSupplyIndex
  /// @notice The block number the index was last updated at
  struct CompMarketState {
    uint224 index;
    uint32 block;
  }
  uint256 public constant percentScale = 1e14;
  address public comp;

  IComptroller public comptroller;
  /// @notice The COMP accrued but not yet transferred to each user
  mapping(address => uint256) public compAccrued;
  /// @notice The portion of COMP that each contributor receives per block
  mapping(address => uint256) public compContributorSpeeds;
  /// @notice The initial COMP index for a market
  uint224 public constant compInitialIndex = 1e36;
  /// @notice Last block at which a contributor's COMP rewards have been allocated
  mapping(address => uint256) public lastContributorBlock;
  /// @notice The COMP borrow index for each market for each supplier as of the last time they accrued COMP
  mapping(address => mapping(address => uint256)) public compSupplierIndex;
  /// @notice The COMP borrow index for each market for each borrower as of the last time they accrued COMP
  mapping(address => mapping(address => uint256)) public compBorrowerIndex;
  /// @notice The rate at which comp is distributed to the corresponding supply market (per block)
  mapping(address => uint256) public compSupplySpeeds;
  /// @notice The rate at which comp is distributed to the corresponding borrow market (per block)
  mapping(address => uint256) public compBorrowSpeeds;
  /// @notice The COMP market supply state for each market
  mapping(address => CompMarketState) public compSupplyState;
  /// @notice The COMP market borrow state for each market
  mapping(address => CompMarketState) public compBorrowState;

  /// @notice Emitted when COMP is granted by admin
  event CompGranted(address recipient, uint256 amount);
  /// @notice Emitted when a new COMP speed is set for a contributor
  event ContributorCompSpeedUpdated(address indexed contributor, uint256 newSpeed);
  /// @notice Emitted when a new supply-side COMP speed is calculated for a market
  event CompSupplySpeedUpdated(address indexed cToken, uint256 newSpeed);
  /// @notice Emitted when a new borrow-side COMP speed is calculated for a market
  event CompBorrowSpeedUpdated(address indexed cToken, uint256 newSpeed);
  /// @notice Emitted when COMP is distributed to a supplier
  event DistributedSupplierComp(
    address indexed cToken,
    address indexed supplier,
    uint256 compDelta,
    uint256 compSupplyIndex
  );

  /// @notice Emitted when COMP is distributed to a borrower
  event DistributedBorrowerComp(
    address indexed cToken,
    address indexed borrower,
    uint256 compDelta,
    uint256 compBorrowIndex
  );

  modifier onlyComptroller() {
    require(msg.sender == address(comptroller), 'only comptroller');
    _;
  }

  constructor() {
    _disableInitializers();
  }

  function initialize(address _admin, address _comp) external initializer {
    comp = _comp;
    _setupRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  event SetComptroller(address comptroller);

  function setComptroller(IComptroller _comptroller) external onlyRole(DEFAULT_ADMIN_ROLE) {
    comptroller = _comptroller;
    emit SetComptroller(address(comptroller));
  }

  /*** Comp Distribution ***/

  /**
   * @notice Set COMP speed for a single market
   * @param cToken The market whose COMP speed to update
   * @param supplySpeed New supply-side COMP speed for market
   * @param borrowSpeed New borrow-side COMP speed for market
   */
  function setCompSpeed(address cToken, uint256 supplySpeed, uint256 borrowSpeed) external onlyComptroller {
    _setCompSpeedInternal(cToken, supplySpeed, borrowSpeed);
  }

  function _setCompSpeedInternal(address cToken, uint256 supplySpeed, uint256 borrowSpeed) private {
    (bool isListed, , ) = comptroller.markets(cToken);
    require(isListed, 'market not listed');
    require(supplySpeed > 0, 'invalid supplySpeed');
    require(borrowSpeed > 0, 'invlaid borrowSpeed');

    if (compSupplySpeeds[cToken] != supplySpeed) {
      // Supply speed updated so let's update supply state to ensure that
      //  1. COMP accrued properly for the old speed, and
      //  2. COMP accrued at the new speed starts after this block.
      _updateCompSupplyIndex(cToken);

      // Update speed and emit event
      compSupplySpeeds[cToken] = supplySpeed;
      emit CompSupplySpeedUpdated(cToken, supplySpeed);
    }

    if (compBorrowSpeeds[cToken] != borrowSpeed) {
      // Borrow speed updated so let's update borrow state to ensure that
      //  1. COMP accrued properly for the old speed, and
      //  2. COMP accrued at the new speed starts after this block.
      Exp memory borrowIndex = Exp({mantissa: ICToken(cToken).borrowIndex()});
      _updateCompBorrowIndex(cToken, borrowIndex);

      // Update speed and emit event
      compBorrowSpeeds[cToken] = borrowSpeed;
      emit CompBorrowSpeedUpdated(cToken, borrowSpeed);
    }
  }

  /**
   * @notice Accrue COMP to the market by updating the supply index
   * @param cToken The market whose supply index to update
   * @dev Index is a cumulative sum of the COMP per cToken accrued.
   */
  function updateCompSupplyIndex(address cToken) external onlyComptroller {
    _updateCompSupplyIndex(cToken);
  }

  function _updateCompSupplyIndex(address cToken) private {
    CompMarketState storage supplyState = compSupplyState[cToken];
    uint256 supplySpeed = compSupplySpeeds[cToken];
    uint32 blockNumber = safe32(block.number, 'block number exceeds 32 bits');
    uint256 deltaBlocks = uint256(blockNumber) - (uint256(supplyState.block));
    if (deltaBlocks != 0 && supplySpeed != 0) {
      uint256 supplyTokens = ICToken(cToken).totalSupply();
      uint256 _compAccrued = deltaBlocks * supplySpeed;
      Double memory ratio = supplyTokens > 0 ? fraction(_compAccrued, supplyTokens) : Double({mantissa: 0});
      supplyState.index = safe224(
        add_(Double({mantissa: supplyState.index}), ratio).mantissa,
        'new index exceeds 224 bits'
      );
      supplyState.block = blockNumber;
    } else if (deltaBlocks > 0) {
      supplyState.block = blockNumber;
    }
  }

  /**
   * @notice Accrue COMP to the market by updating the borrow index
   * @param cToken The market whose borrow index to update
   * @dev Index is a cumulative sum of the COMP per cToken accrued.
   */

  function updateCompBorrowIndex(address cToken, Exp memory marketBorrowIndex) external onlyComptroller {
    _updateCompBorrowIndex(cToken, marketBorrowIndex);
  }

  function _updateCompBorrowIndex(address cToken, Exp memory marketBorrowIndex) private {
    CompMarketState storage borrowState = compBorrowState[cToken];
    uint256 borrowSpeed = compBorrowSpeeds[cToken];
    uint32 blockNumber = safe32(block.number, 'block number exceeds 32 bits');
    uint256 deltaBlocks = uint256(blockNumber) - uint256(borrowState.block);
    if (deltaBlocks > 0 && borrowSpeed > 0) {
      uint256 borrowAmount = div_(ICToken(cToken).totalBorrows(), marketBorrowIndex);
      uint256 _compAccrued = deltaBlocks * borrowSpeed;
      Double memory ratio = borrowAmount > 0 ? fraction(_compAccrued, borrowAmount) : Double({mantissa: 0});
      borrowState.index = safe224(
        add_(Double({mantissa: borrowState.index}), ratio).mantissa,
        'new index exceeds 224 bits'
      );
      borrowState.block = blockNumber;
    } else if (deltaBlocks > 0) {
      borrowState.block = blockNumber;
    }
  }

  /**
   * @notice Calculate COMP accrued by a supplier and possibly transfer it to them
   * @param cToken The market in which the supplier is interacting
   * @param supplier The address of the supplier to distribute COMP to
   */

  function distributeSupplierComp(address cToken, address supplier) external onlyComptroller {
    _distributeSupplierComp(cToken, supplier);
  }

  function _distributeSupplierComp(address cToken, address supplier) private {
    // This check should be as gas efficient as possible as distributeSupplierComp is called in many places.
    // - We really don't want to call an external contract as that's quite expensive.

    CompMarketState storage supplyState = compSupplyState[cToken];
    uint256 supplyIndex = supplyState.index;
    uint256 supplierIndex = compSupplierIndex[cToken][supplier];

    // Update supplier's index to the current index since we are distributing accrued COMP
    compSupplierIndex[cToken][supplier] = supplyIndex;

    if (supplierIndex == 0 && supplyIndex >= compInitialIndex) {
      // Covers the case where users supplied tokens before the market's supply state index was set.
      // Rewards the user with COMP accrued from the start of when supplier rewards were first
      // set for the market.
      supplierIndex = compInitialIndex;
    }

    // Calculate change in the cumulative sum of the COMP per cToken accrued
    Double memory deltaIndex = Double({mantissa: supplyIndex - supplierIndex});

    uint256 supplierTokens = ICToken(cToken).balanceOf(supplier);

    // Calculate COMP accrued: cTokenAmount * accruedPerCTokenInterface
    uint256 supplierDelta = mul_(supplierTokens, deltaIndex);

    uint256 supplierAccrued = compAccrued[supplier] + supplierDelta;
    compAccrued[supplier] = supplierAccrued;

    emit DistributedSupplierComp(cToken, supplier, supplierDelta, supplyIndex);
  }

  /**
   * @notice Calculate COMP accrued by a borrower and possibly transfer it to them
   * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
   * @param cToken The market in which the borrower is interacting
   * @param borrower The address of the borrower to distribute COMP to
   */
  function distributeBorrowerComp(
    address cToken,
    address borrower,
    Exp memory marketBorrowIndex
  ) external onlyComptroller {
    _distributeBorrowerComp(cToken, borrower, marketBorrowIndex);
  }

  function _distributeBorrowerComp(address cToken, address borrower, Exp memory marketBorrowIndex) private {
    // This check should be as gas efficient as possible as distributeBorrowerComp is called in many places.
    // - We really don't want to call an external contract as that's quite expensive.

    CompMarketState storage borrowState = compBorrowState[cToken];
    uint256 borrowIndex = borrowState.index;
    uint256 borrowerIndex = compBorrowerIndex[cToken][borrower];

    // Update borrowers's index to the current index since we are distributing accrued COMP
    compBorrowerIndex[cToken][borrower] = borrowIndex;

    if (borrowerIndex == 0 && borrowIndex >= compInitialIndex) {
      // Covers the case where users borrowed tokens before the market's borrow state index was set.
      // Rewards the user with COMP accrued from the start of when borrower rewards were first
      // set for the market.
      borrowerIndex = compInitialIndex;
    }

    // Calculate change in the cumulative sum of the COMP per borrowed unit accrued
    Double memory deltaIndex = Double({mantissa: borrowIndex - borrowerIndex});

    uint256 borrowerAmount = div_(ICToken(cToken).borrowBalanceStored(borrower), marketBorrowIndex);

    // Calculate COMP accrued: cTokenAmount * accruedPerBorrowedUnit
    uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);

    uint256 borrowerAccrued = compAccrued[borrower] + borrowerDelta;
    compAccrued[borrower] = borrowerAccrued;

    emit DistributedBorrowerComp(cToken, borrower, borrowerDelta, borrowIndex);
  }

  /**
   * @notice Calculate additional accrued COMP for a contributor since last accrual
   * @param contributor The address to calculate contributor rewards for
   */
  function updateContributorRewards(address contributor) public {
    uint256 compSpeed = compContributorSpeeds[contributor];
    uint256 blockNumber = block.number;
    uint256 deltaBlocks = blockNumber - lastContributorBlock[contributor];
    if (deltaBlocks > 0 && compSpeed > 0) {
      uint256 newAccrued = deltaBlocks * compSpeed;
      uint256 contributorAccrued = compAccrued[contributor] + newAccrued;

      compAccrued[contributor] = contributorAccrued;
      lastContributorBlock[contributor] = blockNumber;
    }
  }

  /**
   * @notice Claim all the comp accrued by holder in all markets
   * @param holder The address to claim COMP for
   */
  function claimSumer(address holder) public {
    return claimSumer(holder, comptroller.getAllMarkets());
  }

  /**
   * @notice Claim all the comp accrued by holder in the specified markets
   * @param holder The address to claim COMP for
   * @param cTokens The list of markets to claim COMP in
   */
  function claimSumer(address holder, address[] memory cTokens) public {
    address[] memory holders = new address[](1);
    holders[0] = holder;
    claimSumer(holders, cTokens, true, true);
  }

  /**
   * @notice Claim all comp accrued by the holders
   * @param holders The addresses to claim COMP for
   * @param cTokens The list of markets to claim COMP in
   * @param borrowers Whether or not to claim COMP earned by borrowing
   * @param suppliers Whether or not to claim COMP earned by supplying
   */
  function claimSumer(address[] memory holders, address[] memory cTokens, bool borrowers, bool suppliers) public {
    for (uint256 i = 0; i < cTokens.length; ++i) {
      address cToken = cTokens[i];
      (bool isListed, , ) = comptroller.markets(cToken);
      require(isListed, 'market not listed');
      if (borrowers) {
        Exp memory borrowIndex = Exp({mantissa: ICToken(cToken).borrowIndex()});
        _updateCompBorrowIndex(cToken, borrowIndex);
        for (uint256 j = 0; j < holders.length; j++) {
          _distributeBorrowerComp(cToken, holders[j], borrowIndex);
        }
      }
      if (suppliers) {
        _updateCompSupplyIndex(cToken);
        for (uint256 j = 0; j < holders.length; j++) {
          _distributeSupplierComp(cToken, holders[j]);
        }
      }
    }
    for (uint256 j = 0; j < holders.length; j++) {
      compAccrued[holders[j]] = grantCompInternal(holders[j], compAccrued[holders[j]]);
    }
  }

  /**
   * @notice Transfer COMP to the user
   * @dev Note: If there is not enough COMP, we do not perform the transfer at all.
   * @param user The address of the user to transfer COMP to
   * @param amount The amount of COMP to (possibly) transfer
   * @return The amount of COMP which was NOT transferred to the user
   */
  function grantCompInternal(address user, uint256 amount) private returns (uint256) {
    address[] memory markets = comptroller.getAssetsIn(user);
    /***
        for (uint i = 0; i < allMarkets.length; ++i) {
            address market = address(allMarkets[i]);
        ***/
    for (uint256 i = 0; i < markets.length; ++i) {
      address market = address(markets[i]);
      bool noOriginalSpeed = compBorrowSpeeds[market] == 0;
      bool invalidSupply = noOriginalSpeed && compSupplierIndex[market][user] > 0;
      bool invalidBorrow = noOriginalSpeed && compBorrowerIndex[market][user] > 0;

      if (invalidSupply || invalidBorrow) {
        return amount;
      }
    }

    uint256 compRemaining = ICToken(comp).balanceOf(address(this));
    if (amount > 0 && amount <= compRemaining) {
      (bool success, ) = comp.call(abi.encodeWithSignature('transfer(address,uint256)', user, amount));
      require(success, 'cant transfer');
      return 0;
    }
    return amount;
  }

  function initializeMarket(address cToken, uint32 blockNumber) external onlyComptroller {
    CompMarketState storage supplyState = compSupplyState[cToken];
    CompMarketState storage borrowState = compBorrowState[cToken];
    /*
     * Update market state indices
     */
    if (supplyState.index == 0) {
      // Initialize supply state index with default value
      supplyState.index = compInitialIndex;
    }
    if (borrowState.index == 0) {
      // Initialize borrow state index with default value
      borrowState.index = compInitialIndex;
    }
    /*
     * Update market state block numbers
     */
    supplyState.block = borrowState.block = blockNumber;
  }

  function uninitializeMarket(address cToken) external onlyComptroller {
    if (compSupplyState[cToken].index == compInitialIndex) {
      delete compSupplyState[cToken];
    }
    if (compSupplyState[cToken].index == compInitialIndex) {
      delete compBorrowState[cToken];
    }
  }

  /*** Comp Distribution Admin ***/
  /**
   * @notice Transfer COMP to the recipient
   * @dev Note: If there is not enough COMP, we do not perform the transfer at all.
   * @param recipient The address of the recipient to transfer COMP to
   * @param amount The amount of COMP to (possibly) transfer
   */
  function _grantComp(address recipient, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 amountLeft = grantCompInternal(recipient, amount);
    require(amountLeft == 0, 'insufficient comp for grant');
    emit CompGranted(recipient, amount);
  }

  /**
   * @notice Set COMP borrow and supply speeds for the specified markets.
   * @param cTokens The markets whose COMP speed to update.
   * @param supplySpeeds New supply-side COMP speed for the corresponding market.
   * @param borrowSpeeds New borrow-side COMP speed for the corresponding market.
   */
  function _setCompSpeeds(
    address[] memory cTokens,
    uint256[] memory supplySpeeds,
    uint256[] memory borrowSpeeds
  ) public onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 numTokens = cTokens.length;
    require(
      numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length,
      'Comptroller::_setCompSpeeds invalid input'
    );

    for (uint256 i = 0; i < numTokens; ++i) {
      _setCompSpeedInternal(cTokens[i], supplySpeeds[i], borrowSpeeds[i]);
    }
  }

  /**
   * @notice Set COMP speed for a single contributor
   * @param contributor The contributor whose COMP speed to update
   * @param compSpeed New COMP speed for contributor
   */
  function _setContributorCompSpeed(address contributor, uint256 compSpeed) public onlyRole(DEFAULT_ADMIN_ROLE) {
    // note that COMP speed could be set to 0 to halt liquidity rewards for a contributor
    updateContributorRewards(contributor);
    if (compSpeed == 0) {
      // release storage
      delete lastContributorBlock[contributor];
    } else {
      lastContributorBlock[contributor] = block.number;
    }
    compContributorSpeeds[contributor] = compSpeed;

    emit ContributorCompSpeedUpdated(contributor, compSpeed);
  }

  function calculateComp(address holder) external view returns (uint256) {
    address[] memory cTokens = comptroller.getAllMarkets();
    uint256 accrued = compAccrued[holder];
    for (uint256 i = 0; i < cTokens.length; ++i) {
      address cToken = cTokens[i];
      Exp memory marketBorrowIndex = Exp({mantissa: ICToken(cToken).borrowIndex()});
      // _updateCompBorrowIndex
      CompMarketState memory borrowState = compBorrowState[cToken];
      uint256 borrowSpeed = compBorrowSpeeds[cToken];
      uint32 blockNumber = safe32(block.number, 'block number exceeds 32 bits');
      uint256 borrowDeltaBlocks = uint256(blockNumber - uint256(borrowState.block));
      if (borrowDeltaBlocks > 0 && borrowSpeed > 0) {
        uint256 borrowAmount = div_(ICToken(cToken).totalBorrows(), marketBorrowIndex);
        uint256 _compAccrued = borrowDeltaBlocks * borrowSpeed;
        Double memory ratio = borrowAmount > 0 ? fraction(_compAccrued, borrowAmount) : Double({mantissa: 0});
        borrowState.index = safe224(
          add_(Double({mantissa: borrowState.index}), ratio).mantissa,
          'new index exceeds 224 bits'
        );
        borrowState.block = blockNumber;
      } else if (borrowDeltaBlocks > 0) {
        borrowState.block = blockNumber;
      }
      // _distributeBorrowerComp
      uint256 borrowIndex = borrowState.index;
      uint256 borrowerIndex = compBorrowerIndex[cToken][holder];
      if (borrowerIndex == 0 && borrowIndex >= compInitialIndex) {
        borrowerIndex = compInitialIndex;
      }
      Double memory borrowDeltaIndex = Double({mantissa: borrowIndex - borrowerIndex});
      uint256 borrowerAmount = div_(ICToken(cToken).borrowBalanceStored(holder), marketBorrowIndex);
      uint256 borrowerDelta = mul_(borrowerAmount, borrowDeltaIndex);
      accrued = accrued + borrowerDelta;
      // _updateCompSupplyIndex
      CompMarketState memory supplyState = compSupplyState[cToken];
      uint256 supplySpeed = compSupplySpeeds[cToken];
      uint256 supplyDeltaBlocks = uint256(blockNumber) - uint256(supplyState.block);
      if (supplyDeltaBlocks > 0 && supplySpeed > 0) {
        uint256 supplyTokens = ICToken(cToken).totalSupply();
        uint256 _compAccrued = supplyDeltaBlocks * supplySpeed;
        Double memory ratio = supplyTokens > 0 ? fraction(_compAccrued, supplyTokens) : Double({mantissa: 0});
        supplyState.index = safe224(
          add_(Double({mantissa: supplyState.index}), ratio).mantissa,
          'new index exceeds 224 bits'
        );
        supplyState.block = blockNumber;
      } else if (supplyDeltaBlocks > 0) {
        supplyState.block = blockNumber;
      }
      // _distributeSupplierComp
      uint256 supplyIndex = supplyState.index;
      uint256 supplierIndex = compSupplierIndex[cToken][holder];
      if (supplierIndex == 0 && supplyIndex >= compInitialIndex) {
        supplierIndex = compInitialIndex;
      }
      Double memory supplyDeltaIndex = Double({mantissa: supplyIndex - supplierIndex});
      uint256 supplierTokens = ICToken(cToken).balanceOf(holder);
      uint256 supplierDelta = mul_(supplierTokens, supplyDeltaIndex);
      accrued = accrued + supplierDelta;
    }
    return accrued;
  }

  /////////////////////////////////////////////////////////
  // Hypothetical Calculation
  /////////////////////////////////////////////////////////
  /**
   * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
   * @param account The account to determine liquidity for
   * @param cTokenModify The market to hypothetically redeem/borrow in
   * @param intraSafeLimitMantissa The safe limit rate for intra group liquidity
   * @param interSafeLimitMantissa The safe limit rate for inter group liquidity
   * @return (hypothetical account liquidity in excess of collateral requirements)
   */
  function getHypotheticalSafeLimit(
    address account,
    address cTokenModify,
    uint256 intraSafeLimitMantissa,
    uint256 interSafeLimitMantissa
  ) external view returns (uint256) {
    IComptroller c = IComptroller(comptroller);
    bool interMintAllowed = c.interMintAllowed();
    uint256 assetsGroupNum = c.globalConfig().largestGroupId + 1;
    GroupVar[] memory groupVars = new GroupVar[](assetsGroupNum);
    bool targetIsSuToken = (cTokenModify != address(0)) && !ICToken(cTokenModify).isCToken();
    uint256 redeemTokens = 0;
    uint256 borrowAmount = 0;

    uint256 sumLiquidity = 0;
    uint256 sumBorrowPlusEffects = 0;
    uint256 sumInterCBorrowVal = 0;
    uint256 sumInterSuBorrowVal = 0;
    GroupVar memory targetGroup;

    // For each asset the account is in
    address[] memory assets = c.getAssetsIn(account);

    // loop through tokens to add deposit/borrow for ctoken/sutoken in each group
    for (uint256 i = 0; i < assets.length; ++i) {
      address asset = assets[i];
      uint256 depositVal = 0;
      uint256 borrowVal = 0;

      (, uint8 assetGroupId, ) = c.markets(asset);
      if (groupVars[assetGroupId].groupId == 0) {
        CompactAssetGroup memory g = c.assetGroup(assetGroupId);
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
      uint256 oraclePriceMantissa = c.getUnderlyingPriceNormalized(asset);

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
    // end of loop in assets

    // loop in groups to calculate accumulated collateral/liability for two types:
    // inter-group and intra-group for target token
    (, uint8 targetGroupId, ) = c.markets(cTokenModify);

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
      return 0;
    }

    if (targetIsSuToken) {
      if (!interMintAllowed) {
        sumLiquidity = 0;
      }
      sumLiquidity = (sumLiquidity * interSafeLimitMantissa) / expScale;
      // if target is sutoken
      // limit = inter-group limit + intra ctoken collateral * intra mint rate
      sumLiquidity +=
        (targetGroup.intraMintRate * targetGroup.cDepositVal * intraSafeLimitMantissa) /
        expScale /
        expScale;
    } else {
      // if target is not sutoken
      // limit = inter-group limit + intra ctoken collateral * intra c rate
      sumLiquidity = (sumLiquidity * interSafeLimitMantissa) / expScale;
      sumLiquidity += (targetGroup.intraCRate * targetGroup.cDepositVal * intraSafeLimitMantissa) / expScale / expScale;
    }

    // limit = inter-group limit + intra-group ctoken limit + intra sutoken collateral * intra su rate
    sumLiquidity += (targetGroup.intraSuRate * targetGroup.suDepositVal * intraSafeLimitMantissa) / expScale / expScale;

    return sumLiquidity;
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
}
