// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import '../Exponential/ExponentialNoErrorNew.sol';
import '../Interfaces/IComptroller.sol';
import '../Interfaces/ICTokenExternal.sol';
import '../Interfaces/IPriceOracle.sol';
import '@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol';
import '../SumerErrors.sol';

contract AccountLiquidity is AccessControlEnumerableUpgradeable, ExponentialNoErrorNew, SumerErrors {
  IComptroller public comptroller;

  constructor() {
    _disableInitializers();
  }

  function initialize(address _admin) external initializer {
    _setupRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  function setComptroller(IComptroller _comptroller) external onlyRole(DEFAULT_ADMIN_ROLE) {
    comptroller = _comptroller;
  }

  struct AccountGroupLocalVars {
    uint8 groupId;
    uint256 cDepositVal;
    uint256 cBorrowVal;
    uint256 suDepositVal;
    uint256 suBorrowVal;
    Exp intraCRate;
    Exp intraMintRate;
    Exp intraSuRate;
    Exp interCRate;
    Exp interSuRate;
  }

  function getGroupSummary(
    address account,
    address cTokenModify,
    uint256 redeemTokens,
    uint256 borrowAmount
  ) internal view returns (uint256, uint256, AccountGroupLocalVars memory) {
    IComptroller.AssetGroup[] memory assetGroups = IComptroller(comptroller).getAllAssetGroup();
    uint256 assetsGroupNum = assetGroups.length;
    AccountGroupLocalVars[] memory groupVars = new AccountGroupLocalVars[](assetsGroupNum);

    uint256 sumLiquidity = 0;
    uint256 sumBorrowPlusEffects = 0;
    AccountGroupLocalVars memory targetGroup;

    for (uint256 i = 0; i < assetsGroupNum; i++) {
      IComptroller.AssetGroup memory g = assetGroups[i];
      groupVars[i] = AccountGroupLocalVars(
        g.groupId,
        0,
        0,
        0,
        0,
        Exp({mantissa: g.intraCRateMantissa}),
        Exp({mantissa: g.intraMintRateMantissa}),
        Exp({mantissa: g.intraSuRateMantissa}),
        Exp({mantissa: g.interCRateMantissa}),
        Exp({mantissa: g.interSuRateMantissa})
      );
    }

    // For each asset the account is in
    address[] memory assets = comptroller.getAssetsIn(account);

    // loop through tokens to add deposit/borrow for ctoken/sutoken in each group
    for (uint256 i = 0; i < assets.length; ++i) {
      address asset = assets[i];
      uint256 depositVal = 0;
      uint256 borrowVal = 0;

      (, uint8 assetGroupId, ) = comptroller.markets(asset);
      (uint256 oErr, uint256 depositBalance, uint256 borrowBalance, uint256 exchangeRateMantissa) = ICToken(asset)
        .getAccountSnapshot(account);
      require(oErr == 0, 'snapshot error');

      // Get price of asset
      uint256 oraclePriceMantissa = comptroller.getUnderlyingPriceNormalized(asset);
      // normalize price for asset with unit of 1e(36-token decimal)
      Exp memory oraclePrice = Exp({mantissa: oraclePriceMantissa});

      // Pre-compute a conversion factor from tokens -> USD (normalized price value)
      // tokensToDenom = oraclePrice * exchangeRate * discourntRate
      Exp memory exchangeRate = Exp({mantissa: exchangeRateMantissa});
      Exp memory discountRate = Exp({mantissa: ICToken(asset).discountRateMantissa()});
      Exp memory tokensToDenom = mul_(mul_(exchangeRate, oraclePrice), discountRate);

      depositVal = mul_ScalarTruncateAddUInt(tokensToDenom, depositBalance, depositVal);
      borrowVal = mul_ScalarTruncateAddUInt(oraclePrice, borrowBalance, borrowVal);
      if (asset == cTokenModify) {
        uint256 redeemVal = truncate(mul_(tokensToDenom, redeemTokens));
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

        borrowVal = mul_ScalarTruncateAddUInt(oraclePrice, borrowAmount, borrowVal);
      }

      uint8 index = comptroller.assetGroupIdToIndex(assetGroupId);

      if (ICToken(asset).isCToken()) {
        groupVars[index].cDepositVal = depositVal + groupVars[index].cDepositVal;
        groupVars[index].cBorrowVal = borrowVal + groupVars[index].cBorrowVal;
      } else {
        groupVars[index].suDepositVal = depositVal + groupVars[index].suDepositVal;
        groupVars[index].suBorrowVal = borrowVal + groupVars[index].suBorrowVal;
      }
    }
    // end of loop in assets

    // loop in groups to calculate accumulated collateral/liability for two types:
    // inter-group and intra-group for target token
    (, uint8 targetGroupId, ) = comptroller.markets(cTokenModify);

    for (uint8 i = 0; i < assetsGroupNum; ++i) {
      if (groupVars[i].groupId == 0) {
        continue;
      }
      AccountGroupLocalVars memory g = groupVars[i];

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
        sumLiquidity = mul_ScalarTruncateAddUInt(g.interCRate, g.cDepositVal, sumLiquidity);
        sumLiquidity = mul_ScalarTruncateAddUInt(g.interSuRate, g.suDepositVal, sumLiquidity);
        sumBorrowPlusEffects = sumBorrowPlusEffects + g.cBorrowVal + g.suBorrowVal;
      }
    }

    if (sumLiquidity > sumBorrowPlusEffects) {
      sumLiquidity = sumLiquidity - sumBorrowPlusEffects;
      sumBorrowPlusEffects = 0;
    } else {
      sumBorrowPlusEffects = sumBorrowPlusEffects - sumLiquidity;
      sumLiquidity = 0;
    }

    // absorb target group ctoken loan with other group collateral
    if (targetGroup.cBorrowVal > 0 && sumLiquidity > 0) {
      if (sumLiquidity > targetGroup.cBorrowVal) {
        sumLiquidity = sumLiquidity - targetGroup.cBorrowVal;
        targetGroup.cBorrowVal = 0;
      } else {
        targetGroup.cBorrowVal = targetGroup.cBorrowVal - sumLiquidity;
        sumLiquidity = 0;
      }
    }

    // absorb target group sutoken loan with other group collateral
    if (targetGroup.suBorrowVal > 0 && sumLiquidity > 0) {
      if (sumLiquidity > targetGroup.suBorrowVal) {
        sumLiquidity = sumLiquidity - targetGroup.suBorrowVal;
        targetGroup.suBorrowVal = 0;
      } else {
        targetGroup.suBorrowVal = targetGroup.suBorrowVal - sumLiquidity;
        sumLiquidity = 0;
      }
    }

    // absorb inter group loan with target group ctoken collateral
    if (sumBorrowPlusEffects > 0) {
      (targetGroup.cDepositVal, sumBorrowPlusEffects) = absorbLoan(
        targetGroup.cDepositVal,
        sumBorrowPlusEffects,
        targetGroup.interCRate
      );
    }

    // absorb inter group loan with target group sutoken collateral
    if (sumBorrowPlusEffects > 0) {
      (targetGroup.suDepositVal, sumBorrowPlusEffects) = absorbLoan(
        targetGroup.suDepositVal,
        sumBorrowPlusEffects,
        targetGroup.interSuRate
      );
    }
    return (sumLiquidity, sumBorrowPlusEffects, targetGroup);
  }

  function getHypotheticalSafeLimit(
    address account,
    address cTokenModify,
    uint256 intraSafeLimitMantissa,
    uint256 interSafeLimitMantissa
  ) external view returns (uint256) {
    (uint256 sumLiquidity, uint256 sumBorrowPlusEffects, AccountGroupLocalVars memory targetGroup) = getGroupSummary(
      account,
      cTokenModify,
      uint256(0),
      uint256(0)
    );

    Exp memory intraSafeLimit = Exp({mantissa: intraSafeLimitMantissa});
    Exp memory interSafeLimit = Exp({mantissa: interSafeLimitMantissa});
    bool targetIsSuToken = (cTokenModify != address(0)) && !ICToken(cTokenModify).isCToken();
    uint256 interGroupLiquidity = sumLiquidity;
    uint256 intraGroupLiquidity = mul_ScalarTruncate(targetGroup.intraSuRate, targetGroup.suDepositVal);

    if (targetIsSuToken) {
      intraGroupLiquidity = mul_ScalarTruncateAddUInt(
        targetGroup.intraMintRate,
        targetGroup.cDepositVal,
        intraGroupLiquidity
      );
    } else {
      intraGroupLiquidity = mul_ScalarTruncateAddUInt(
        targetGroup.intraCRate,
        targetGroup.cDepositVal,
        intraGroupLiquidity
      );
    }

    sumLiquidity = interGroupLiquidity + intraGroupLiquidity;
    if (sumLiquidity <= sumBorrowPlusEffects) {
      return 0;
    }

    uint256 safeLimit = mul_ScalarTruncateAddUInt(interSafeLimit, interGroupLiquidity, 0);
    safeLimit = mul_ScalarTruncateAddUInt(intraSafeLimit, intraGroupLiquidity, safeLimit);
    return safeLimit;
  }

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
  ) external view returns (uint256, uint256) {
    (uint256 sumLiquidity, uint256 sumBorrowPlusEffects, AccountGroupLocalVars memory targetGroup) = getGroupSummary(
      account,
      cTokenModify,
      redeemTokens,
      borrowAmount
    );
    bool targetIsSuToken = (cTokenModify != address(0)) && !ICToken(cTokenModify).isCToken();

    if (targetIsSuToken) {
      // if target is sutoken
      // limit = inter-group limit + intra ctoken collateral * intra mint rate
      sumLiquidity = mul_ScalarTruncateAddUInt(targetGroup.intraMintRate, targetGroup.cDepositVal, sumLiquidity);
    } else {
      // if target is not sutoken
      // limit = inter-group limit + intra ctoken collateral * intra c rate
      sumLiquidity = mul_ScalarTruncateAddUInt(targetGroup.intraCRate, targetGroup.cDepositVal, sumLiquidity);
    }

    // limit = inter-group limit + intra-group ctoken limit + intra sutoken collateral * intra su rate
    sumLiquidity = mul_ScalarTruncateAddUInt(targetGroup.intraSuRate, targetGroup.suDepositVal, sumLiquidity);

    sumBorrowPlusEffects = sumBorrowPlusEffects + targetGroup.cBorrowVal + targetGroup.suBorrowVal;

    if (sumLiquidity > 0 && sumBorrowPlusEffects > 0) {
      revert EitherAssetOrDebtMustBeZero();
    }
    return (sumLiquidity, sumBorrowPlusEffects);
  }

  function absorbLoan(
    uint256 collateralValue,
    uint256 borrowValue,
    Exp memory collateralRate
  ) internal pure returns (uint256, uint256) {
    if (collateralRate.mantissa == 0) {
      return (0, borrowValue);
    }
    uint256 collateralizedLoan = mul_ScalarTruncate(collateralRate, collateralValue);
    uint256 usedCollateral = div_(borrowValue, collateralRate);
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
