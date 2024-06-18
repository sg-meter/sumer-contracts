pragma solidity 0.8.19;

import '../Interfaces/IRedemptionManager.sol';
import '../Interfaces/IComptroller.sol';
import './SortedBorrows.sol';
import '../Interfaces/IPriceOracle.sol';
import './LiquityMath.sol';
import '@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '../Exponential/ExponentialNoErrorNew.sol';
import '../SumerErrors.sol';
import '../Interfaces/IEIP712.sol';

contract RedemptionManager is
  AccessControlEnumerableUpgradeable,
  IRedemptionManager,
  ExponentialNoErrorNew,
  SumerErrors
{
  // deprecated, leaving to keep storage layout the same
  IComptroller public comptroller;

  /*
   * Half-life of 12h. 12h = 720 min
   * (1/2) = d^720 => d = (1/2)^(1/720)
   */
  uint public constant DECIMAL_PRECISION = 1e18;
  uint public constant SECONDS_IN_ONE_MINUTE = 60;
  uint public constant MINUTE_DECAY_FACTOR = 999037758833783000;
  uint public constant REDEMPTION_FEE_FLOOR = (DECIMAL_PRECISION / 1000) * 5; // 0.5%
  uint public constant MAX_BORROWING_FEE = (DECIMAL_PRECISION / 100) * 5; // 5%

  /*
   * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
   * Corresponds to (1 / ALPHA) in the white paper.
   */
  uint public constant BETA = 2;

  // deprecated field
  // leave it here for compatibility for storage layout
  uint public baseRate;

  // deprecated field
  // leave it here for compatibility for storage layout
  // The timestamp of the latest fee operation (redemption or new LUSD issuance)
  uint public lastFeeOperationTime;

  mapping(address => uint) public baseRateMap;

  // The timestamp of the latest fee operation (redemption or new LUSD issuance)
  mapping(address => uint) public lastFeeOperationTimeMap;

  address public redemptionSigner;

  event BaseRateUpdated(address asset, uint _baseRate);
  event LastFeeOpTimeUpdated(address asset, uint256 timestamp);
  event NewComptroller(address oldComptroller, address newComptroller);
  event NewRedemptionSigner(address oldSigner, address newSigner);

  constructor() {
    _disableInitializers();
  }

  function initialize(address _admin, IComptroller _comptroller, address _redemptionSigner) external initializer {
    comptroller = _comptroller;
    emit NewComptroller(address(0), address(comptroller));
    redemptionSigner = _redemptionSigner;
    emit NewRedemptionSigner(address(0), redemptionSigner);
    _setupRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  function setComptroller(IComptroller _comptroller) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (!_comptroller.isComptroller()) {
      revert InvalidComptroller();
    }
    address oldComptroller = address(comptroller);
    comptroller = _comptroller;
    emit NewComptroller(oldComptroller, address(comptroller));
  }

  function setRedemptionSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
    address oldSigner = redemptionSigner;
    if (signer == address(0)) {
      revert InvalidAddress();
    }
    redemptionSigner = signer;
    emit NewRedemptionSigner(oldSigner, redemptionSigner);
  }

  // function setSortedBorrows(ISortedBorrows _sortedBorrows) external onlyRole(DEFAULT_ADMIN_ROLE) {
  //   require(sortedBorrows.isSortedBorrows(), 'invalid sorted borrows');
  //   sortedBorrows = _sortedBorrows;
  // }

  /*
   * This function has two impacts on the baseRate state variable:
   * 1) decays the baseRate based on time passed since last redemption or LUSD borrowing operation.
   * then,
   * 2) increases the baseRate based on the amount redeemed, as a proportion of total supply
   */
  function updateBaseRateFromRedemption(address asset, uint redeemAmount, uint _totalSupply) internal returns (uint) {
    uint newBaseRate = _calcNewBaseRate(asset, redeemAmount, _totalSupply);
    _updateBaseRate(asset, newBaseRate);
    _updateLastFeeOpTime(asset);

    return newBaseRate;
  }

  function _minutesPassedSinceLastFeeOp(address asset) internal view returns (uint) {
    return (block.timestamp - lastFeeOperationTimeMap[asset]) / SECONDS_IN_ONE_MINUTE;
  }

  function getCurrentRedemptionRate(address asset, uint redeemAmount, uint _totalSupply) public view returns (uint) {
    return _calcRedemptionRate(_calcNewBaseRate(asset, redeemAmount, _totalSupply));
  }

  function _calcNewBaseRate(address asset, uint redeemAmount, uint _totalSupply) internal view returns (uint) {
    if (_totalSupply <= 0) {
      return DECIMAL_PRECISION;
    }
    // require(msg.sender == address(comptroller), 'only comptroller');
    uint decayedBaseRate = _calcDecayedBaseRate(asset);

    /* Convert the drawn ETH back to LUSD at face value rate (1 LUSD:1 USD), in order to get
     * the fraction of total supply that was redeemed at face value. */
    uint redeemedLUSDFraction = (redeemAmount * DECIMAL_PRECISION) / _totalSupply;

    uint newBaseRate = decayedBaseRate + (redeemedLUSDFraction / BETA);
    newBaseRate = LiquityMath._min(newBaseRate, DECIMAL_PRECISION); // cap baseRate at a maximum of 100%
    //assert(newBaseRate <= DECIMAL_PRECISION); // This is already enforced in the line above
    assert(newBaseRate > 0); // Base rate is always non-zero after redemption
    return newBaseRate;
  }

  function _calcDecayedBaseRate(address asset) internal view returns (uint) {
    uint minutesPassed = _minutesPassedSinceLastFeeOp(asset);
    uint decayFactor = LiquityMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);

    return (baseRateMap[asset] * decayFactor) / DECIMAL_PRECISION;
  }

  // function _getRedemptionFee(uint _ETHDrawn) internal view returns (uint) {
  //   return _calcRedemptionFee(getRedemptionRate(), _ETHDrawn);
  // }

  function getRedemptionRate(address asset) public view returns (uint) {
    return _calcRedemptionRate(baseRateMap[asset]);
  }

  function _calcRedemptionRate(uint _baseRate) internal pure returns (uint) {
    return
      LiquityMath._min(
        REDEMPTION_FEE_FLOOR + _baseRate,
        DECIMAL_PRECISION // cap at a maximum of 100%
      );
  }

  function calcActualRepayAndSeize(
    uint256 redeemAmount,
    address provider,
    address cToken,
    address csuToken
  ) public returns (uint256, uint256, uint256, uint256) {
    ICToken(cToken).accrueInterest();
    ICToken(csuToken).accrueInterest();

    (uint256 oErr, uint256 depositBalance, , uint256 cExRateMantissa) = ICToken(cToken).getAccountSnapshot(provider);
    require(oErr == 0, 'snapshot error');

    if (depositBalance <= 0) {
      return (0, 0, 0, 0);
    }

    uint256 borrowBalance = ICToken(csuToken).borrowBalanceCurrent(provider);
    if (borrowBalance <= 0) {
      return (0, 0, 0, 0);
    }

    uint256 cash = ICToken(cToken).getCash();
    if (cash <= 0) {
      return (0, 0, 0, 0);
    }

    // get price for csuToken
    uint256 suPriceMantissa = comptroller.getUnderlyingPriceNormalized(csuToken);

    // get price for cToken
    uint256 cPriceMantissa = comptroller.getUnderlyingPriceNormalized(cToken);

    uint256 providerCollateralVal = (cPriceMantissa * depositBalance * cExRateMantissa) / expScale;
    uint256 providerLiabilityVal = (suPriceMantissa * borrowBalance);
    uint256 maxRepayable = LiquityMath._min(providerCollateralVal, providerLiabilityVal) / suPriceMantissa;
    uint256 actualRepay = 0;
    uint256 actualSeize = 0;
    if (redeemAmount <= maxRepayable) {
      actualRepay = redeemAmount;
      actualSeize = (suPriceMantissa * redeemAmount * expScale) / cPriceMantissa / cExRateMantissa;
    } else {
      actualRepay = maxRepayable;
      if (providerCollateralVal <= providerLiabilityVal) {
        actualSeize = depositBalance;
      } else {
        actualSeize = (providerLiabilityVal * expScale) / cPriceMantissa / cExRateMantissa;
      }
    }

    uint256 maxSeize = (cash * expScale) / cExRateMantissa;
    // if there's not enough cash, re-calibrate repay/seize
    if (maxSeize < actualSeize) {
      actualSeize = maxSeize;
      actualRepay = (cPriceMantissa * actualSeize * cExRateMantissa) / suPriceMantissa / expScale;
    }

    return (actualRepay, actualSeize, suPriceMantissa, cPriceMantissa);
  }

  // function hasNoProvider(address _asset) external view returns (bool) {
  //   return sortedBorrows.isEmpty(_asset);
  // }

  // function getFirstProvider(address _asset) external view returns (address) {
  //   return sortedBorrows.getFirst(_asset);
  // }

  // function getNextProvider(address _asset, address _id) external view returns (address) {
  //   return sortedBorrows.getNext(_asset, _id);
  // }

  // Updates the baseRate state variable based on time elapsed since the last redemption or LUSD borrowing operation.
  function decayBaseRateFromBorrowing(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint decayedBaseRate = _calcDecayedBaseRate(asset);
    assert(decayedBaseRate <= DECIMAL_PRECISION); // The baseRate can decay to 0

    baseRateMap[asset] = decayedBaseRate;
    emit BaseRateUpdated(asset, decayedBaseRate);

    _updateLastFeeOpTime(asset);
  }

  function _updateBaseRate(address asset, uint newBaseRate) internal {
    // Update the baseRate state variable
    baseRateMap[asset] = newBaseRate;
    emit BaseRateUpdated(asset, newBaseRate);
  }

  // Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
  function _updateLastFeeOpTime(address asset) internal {
    uint timePassed = block.timestamp - lastFeeOperationTimeMap[asset];

    if (timePassed >= SECONDS_IN_ONE_MINUTE) {
      lastFeeOperationTimeMap[asset] = block.timestamp;
      emit LastFeeOpTimeUpdated(asset, block.timestamp);
    }
  }

  function redeemFaceValueWithProviderPreview(
    address redeemer,
    address provider,
    address cToken,
    address csuToken,
    uint256 redeemAmount,
    uint256 redemptionRateMantissa
  ) external returns (uint256, uint256, uint256, uint256, uint256, uint256) {
    if (redeemer == provider) {
      return (0, 0, 0, 0, 0, 0);
    }

    (uint256 actualRepay, uint256 actualSeize, uint256 repayPrice, uint256 seizePrice) = calcActualRepayAndSeize(
      redeemAmount,
      provider,
      cToken,
      csuToken
    );
    if (actualRepay <= 0 || actualSeize <= 0) {
      return (0, 0, 0, repayPrice, seizePrice, 0);
    }
    // uint256 redemptionRateMantissa = getCurrentRedemptionRate(csuToken, actualRepay, ICToken(csuToken).totalBorrows());
    // uint256 collateralRateMantissa = getCollateralRate(cToken, csuToken);
    uint256 protocolSeizeTokens = (actualSeize * redemptionRateMantissa) / expScale;
    // .mul_( Exp({mantissa: collateralRateMantissa}));
    actualSeize = actualSeize - protocolSeizeTokens;
    return (
      actualRepay,
      actualSeize,
      protocolSeizeTokens,
      repayPrice,
      seizePrice,
      redemptionRateMantissa
      // collateralRateMantissa
    );
  }

  function redeemFaceValueWithProvider(
    address redeemer,
    address provider,
    address cToken,
    address csuToken,
    uint256 redeemAmount,
    uint256 redemptionRateMantissa
  ) internal returns (uint256) {
    (uint256 actualRepay, uint256 actualSeize, , ) = calcActualRepayAndSeize(redeemAmount, provider, cToken, csuToken);
    if (actualRepay <= 0 || actualSeize <= 0) {
      return 0;
    }
    ICToken(csuToken).executeRedemption(redeemer, provider, actualRepay, cToken, actualSeize, redemptionRateMantissa);
    return actualRepay;
  }

  function redeemFaceValueWithPermit(
    address csuToken,
    uint256 amount,
    address[] memory providers,
    uint256 providersDeadline,
    bytes memory providersSignature,
    uint256 permitDeadline,
    bytes memory permitSignature
  ) external {
    address underlying = ICToken(csuToken).underlying();
    IEIP712(underlying).permit(msg.sender, csuToken, amount, permitDeadline, permitSignature);
    return redeemFaceValue(csuToken, amount, providers, providersDeadline, providersSignature);
  }

  // function permit(address[] memory providers, uint256 deadline, bytes memory signature) public pure returns (address) {
  //   bytes32 hash = keccak256(abi.encodePacked(deadline, providers));
  //   bytes memory prefixedMessage = abi.encodePacked('\x19Ethereum Signed Message:\n', '32', hash);

  //   address signer = ECDSAUpgradeable.recover(keccak256(prefixedMessage), signature);
  //   return signer;
  // }

  /**
   * @notice Redeems csuToken with face value
   * @param csuToken The market to do the redemption
   * @param amount The amount of csuToken being redeemed to the market in exchange for collateral
   */
  function redeemFaceValue(
    address csuToken,
    uint256 amount,
    address[] memory providers,
    uint256 deadline,
    bytes memory signature
  ) public {
    if (ICToken(csuToken).isCToken() || !comptroller.isListed(csuToken)) {
      revert InvalidSuToken();
    }
    if (redemptionSigner == address(0)) {
      revert RedemptionSignerNotInitialized();
    }

    if (signature.length != 65) {
      revert InvalidSignatureLength();
    }

    if (block.timestamp >= deadline) {
      revert ExpiredSignature();
    }

    uint256 chainId;
    assembly {
      chainId := chainid()
    }

    bytes32 hash = keccak256(abi.encodePacked(deadline, providers, chainId));
    bytes memory prefixedMessage = abi.encodePacked('\x19Ethereum Signed Message:\n', '32', hash);
    address signer = ECDSAUpgradeable.recover(keccak256(prefixedMessage), signature);
    if (signer != redemptionSigner) {
      revert InvalidSignatureForRedeemFaceValue();
    }

    (, uint8 suGroupId, ) = comptroller.markets(csuToken);
    uint256 actualRedeem = 0;

    updateBaseRateFromRedemption(csuToken, amount, ICToken(csuToken).totalBorrows());
    uint256 redemptionRateMantissa = getRedemptionRate(csuToken);
    uint256 targetRedeemAmount = amount;
    for (uint256 p = 0; p < providers.length && targetRedeemAmount > 0; ++p) {
      address provider = providers[p];
      address[] memory assets = comptroller.getAssetsIn(provider);
      if (msg.sender == provider) {
        continue;
      }

      // redeem face value with homo collateral
      for (uint256 i = 0; i < assets.length && targetRedeemAmount > 0; ++i) {
        // only cToken is allowed to be collateral
        if (!ICToken(assets[i]).isCToken()) {
          continue;
        }
        (, uint8 cGroupId, ) = comptroller.markets(assets[i]);
        if (cGroupId == suGroupId) {
          actualRedeem = redeemFaceValueWithProvider(
            msg.sender,
            provider,
            assets[i],
            csuToken,
            targetRedeemAmount,
            redemptionRateMantissa
          );
          if (actualRedeem < targetRedeemAmount) {
            targetRedeemAmount = targetRedeemAmount - actualRedeem;
          } else {
            targetRedeemAmount = 0;
          }
        }
      }

      // redeem face value with hetero collateral
      for (uint256 i = 0; i < assets.length && targetRedeemAmount > 0; ++i) {
        // only cToken is allowed to be collateral
        if (!ICToken(assets[i]).isCToken()) {
          continue;
        }

        (, uint8 cGroupId, ) = comptroller.markets(assets[i]);
        if (cGroupId != suGroupId) {
          actualRedeem = redeemFaceValueWithProvider(
            msg.sender,
            provider,
            assets[i],
            csuToken,
            targetRedeemAmount,
            redemptionRateMantissa
          );
          if (actualRedeem < targetRedeemAmount) {
            targetRedeemAmount = targetRedeemAmount - actualRedeem;
          } else {
            targetRedeemAmount = 0;
          }
        }
      }
    }

    if (targetRedeemAmount > 0) {
      revert NoRedemptionProvider();
    }
  }
}
