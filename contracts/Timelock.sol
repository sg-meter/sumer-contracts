// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import './Interfaces/ITimelock.sol';
import './Exponential/ExponentialNoErrorNew.sol';
import './Library/RateLimiter.sol';
import './Interfaces/IComptroller.sol';
import './SumerErrors.sol';
import './Interfaces/ICTokenExternal.sol';
import './Comptroller/LiquityMath.sol';

contract Timelock is
  ITimelock,
  AccessControlEnumerableUpgradeable,
  ReentrancyGuardUpgradeable,
  ExponentialNoErrorNew,
  SumerErrors
{
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.UintSet;
  using RateLimiter for RateLimiter.TokenBucket;

  bytes32 public constant EMERGENCY_ADMIN = keccak256('EMERGENCY_ADMIN');
  /// @notice user => agreements ids set
  mapping(address => EnumerableSet.UintSet) private _userAgreements;
  /// @notice ids => agreement
  mapping(uint256 => Agreement) public agreements;
  /// @notice underlying => balances
  mapping(address => uint256) public balances;
  uint256 public agreementCount;
  bool public frozen;

  uint48 public minDelay = 60 * 5; // default to 5min
  uint48 public maxDelay = 60 * 60 * 12; // default to 12 hours
  uint256 public threshold;

  IComptroller public comptroller;
  RateLimiter.TokenBucket rateLimiter;
  event NewThreshold(uint256 oldValue, uint256 newValue);
  event NewMinDelay(uint48 oldValue, uint48 newValue);
  event NewMaxDelay(uint48 oldValue, uint48 newValue);
  event NewLimiter(uint256 oldRate, uint256 newRate, uint256 oldCapacity, uint256 newCapacity);

  constructor() {
    _disableInitializers();
  }

  function initialize(address _admin, uint256 rate, uint256 capacity, uint256 _threshold) external initializer {
    rateLimiter = RateLimiter.TokenBucket({
      rate: rate,
      capacity: capacity,
      tokens: capacity,
      lastUpdated: uint32(block.timestamp),
      isEnabled: true
    });
    emit NewLimiter(0, rate, 0, capacity);

    threshold = _threshold;
    emit NewThreshold(uint256(0), threshold);
    emit NewMinDelay(0, minDelay);
    emit NewMaxDelay(0, maxDelay);

    _setupRole(DEFAULT_ADMIN_ROLE, _admin);
    _setupRole(EMERGENCY_ADMIN, _admin);
  }

  function setComptroller(address _comptroller) external onlyAdmin {
    comptroller = IComptroller(_comptroller);
  }

  function setMinDelay(uint48 newMinDelayInSeconds) external onlyAdmin {
    uint48 oldValue = minDelay;
    minDelay = newMinDelayInSeconds;
    emit NewMinDelay(oldValue, minDelay);
  }

  function setMaxDelay(uint48 newMaxDelayInSeconds) external onlyAdmin {
    uint48 oldValue = maxDelay;
    maxDelay = newMaxDelayInSeconds;
    emit NewMaxDelay(oldValue, maxDelay);
  }

  function setLimiter(uint256 newRate, uint256 newCapacity) external onlyAdmin {
    rateLimiter = RateLimiter.TokenBucket({
      rate: newRate,
      capacity: newCapacity,
      tokens: newCapacity,
      lastUpdated: uint32(block.timestamp),
      isEnabled: true
    });

    uint256 oldRate = rateLimiter.rate;
    uint256 oldCapacity = rateLimiter.capacity;
    emit NewLimiter(oldRate, newRate, oldCapacity, newCapacity);
  }

  function setThreshold(uint256 newThreshold) external onlyAdmin {
    uint256 oldValue = threshold;
    threshold = newThreshold;
    emit NewThreshold(oldValue, threshold);
  }

  /// @notice Consumes value from the rate limiter bucket based on the token value given.
  function consumeValue(uint256 underlyAmount) external onlyListedCToken(msg.sender) {
    uint256 usdValue = getUSDValue(underlyAmount, msg.sender);
    if (usdValue > threshold) {
      revert OverThreshold();
    }
    consumeValueInternal(underlyAmount, msg.sender);
  }

  function getUSDValue(uint256 underlyAmount, address cToken) internal view returns (uint256) {
    uint256 priceMantissa = comptroller.getUnderlyingPriceNormalized(cToken);
    return (priceMantissa * underlyAmount) / expScale;
  }

  function consumeValueInternal(uint256 underlyAmount, address cToken) internal {
    address underlying = ICToken(cToken).underlying();
    uint256 usdValue = getUSDValue(underlyAmount, cToken);

    rateLimiter._consume(usdValue, underlying);
  }

  /**
  @return isTimelockNeeded check if timelock is needed
   */
  function consumeValuePreview(uint256 underlyAmount, address cToken) public view returns (bool) {
    RateLimiter.TokenBucket memory bucket = currentRateLimiterState();
    uint256 usdValue = getUSDValue(underlyAmount, cToken);

    return bucket.tokens >= usdValue && usdValue <= threshold;
  }

  function consumeValueOrResetInternal(uint256 underlyAmount, address cToken) internal {
    RateLimiter.TokenBucket memory bucket = currentRateLimiterState();

    address underlying = ICToken(cToken).underlying();
    uint256 usdValue = getUSDValue(underlyAmount, cToken);

    if (bucket.tokens >= usdValue) {
      rateLimiter._consume(usdValue, underlying);
    } else {
      rateLimiter._resetBucketState();
    }
  }

  function currentState() external view returns (RateLimiter.TokenBucket memory) {
    return currentRateLimiterState();
  }

  /// @notice Gets the token bucket with its values for the block it was requested at.
  /// @return The token bucket.
  function currentRateLimiterState() internal view returns (RateLimiter.TokenBucket memory) {
    return rateLimiter._currentTokenBucketState();
  }

  /// @notice Sets the rate limited config.
  /// @param config The new rate limiter config.
  /// @dev should only be callable by the owner or token limit admin.
  function setRateLimiterConfig(RateLimiter.Config memory config) external onlyAdmin {
    rateLimiter._setTokenBucketConfig(config);
  }

  receive() external payable {}

  modifier onlyAdmin() {
    require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), 'CALLER_NOT_ADMIN');
    _;
  }

  modifier onlyEmergencyAdmin() {
    require(hasRole(EMERGENCY_ADMIN, msg.sender), 'CALLER_NOT_EMERGENCY_ADMIN');
    _;
  }

  modifier onlyListedCToken(address cToken) {
    ICToken(cToken).isCToken();
    if (!comptroller.isListed(cToken)) {
      revert OnlyListedCToken();
    }

    _;
  }

  function rescueAgreement(uint256 agreementId, address to) external onlyEmergencyAdmin {
    Agreement memory agreement = agreements[agreementId];
    require(agreement.isFrozen, 'Agreement is not frozen');

    address underlying = ICToken(agreement.cToken).underlying();

    delete agreements[agreementId];
    _userAgreements[agreement.beneficiary].remove(agreementId);

    emit AgreementClaimed(
      agreementId,
      agreement.beneficiary,
      underlying,
      agreement.actionType,
      agreement.underlyAmount
    );

    IERC20(underlying).safeTransfer(to, agreement.underlyAmount);
    emit RescueAgreement(agreementId, underlying, to, agreement.underlyAmount);
  }

  function createAgreement(
    TimeLockActionType actionType,
    uint256 underlyAmount,
    address beneficiary
  ) external onlyListedCToken(msg.sender) returns (uint256) {
    require(beneficiary != address(0), 'Beneficiary cant be zero address');
    uint256 underlyBalance;
    address underlying = ICToken(msg.sender).underlying();
    if (underlying == address(0)) {
      underlyBalance = address(this).balance;
    } else {
      underlyBalance = IERC20(underlying).balanceOf(address(this));
    }
    require(underlyBalance >= balances[underlying] + underlyAmount, 'balance error');
    balances[underlying] = underlyBalance;

    uint256 agreementId = agreementCount++;
    uint48 timestamp = uint48(block.timestamp);
    agreements[agreementId] = Agreement({
      isFrozen: false,
      actionType: actionType,
      cToken: msg.sender,
      beneficiary: beneficiary,
      timestamp: timestamp,
      agreementId: agreementId,
      underlyAmount: underlyAmount
    });
    _userAgreements[beneficiary].add(agreementId);

    emit AgreementCreated(agreementId, beneficiary, underlying, actionType, underlyAmount, timestamp);
    return agreementId;
  }

  function isAgreementMature(uint256 agreementId) external view returns (bool) {
    Agreement memory agreement = agreements[agreementId];
    if (agreement.isFrozen) {
      return false;
    }
    if (agreement.timestamp + minDelay >= uint48(block.timestamp)) {
      return false;
    }
    if (agreement.timestamp + maxDelay <= uint48(block.timestamp)) {
      return true;
    }
    return consumeValuePreview(agreement.underlyAmount, agreement.cToken);
  }

  function getMinWaitInSeconds(uint256 agreementId) external view returns (uint256) {
    Agreement memory agreement = agreements[agreementId];
    uint256 usdValue = getUSDValue(agreement.underlyAmount, agreement.cToken);
    if (usdValue > rateLimiter.capacity) {
      return maxDelay;
    }
    uint256 waitInBucket = rateLimiter._getMinWaitInSeconds(usdValue);
    uint256 maxVal = LiquityMath._max(minDelay, waitInBucket);
    return LiquityMath._min(maxVal, maxDelay);
  }

  function _validateAndDeleteAgreement(uint256 agreementId) internal returns (Agreement memory) {
    Agreement memory agreement = agreements[agreementId];
    require(msg.sender == agreement.beneficiary, 'Not beneficiary');
    require(!agreement.isFrozen, 'Agreement frozen');

    address underlying = ICToken(agreement.cToken).underlying();

    if (agreement.timestamp + minDelay >= uint48(block.timestamp)) {
      revert MinDelayNotReached();
    }
    if (agreement.timestamp + maxDelay <= uint48(block.timestamp)) {
      consumeValueOrResetInternal(agreement.underlyAmount, agreement.cToken);
    } else {
      consumeValueInternal(agreement.underlyAmount, agreement.cToken);
    }

    delete agreements[agreementId];
    _userAgreements[agreement.beneficiary].remove(agreementId);

    emit AgreementClaimed(
      agreementId,
      agreement.beneficiary,
      underlying,
      agreement.actionType,
      agreement.underlyAmount
    );

    return agreement;
  }

  function claim(uint256[] calldata agreementIds) external nonReentrant {
    require(!frozen, 'TimeLock is frozen');

    for (uint256 index = 0; index < agreementIds.length; index++) {
      Agreement memory agreement = _validateAndDeleteAgreement(agreementIds[index]);
      address underlying = ICToken(agreement.cToken).underlying();
      if (underlying == address(0)) {
        // payable(agreement.beneficiary).transfer(agreement.amount);
        (bool sent, ) = agreement.beneficiary.call{value: agreement.underlyAmount, gas: 40000}(new bytes(0));
        require(sent, 'transfer failed');
        // Address.sendValue(payable(agreement.beneficiary), agreement.underlyAmount);
      } else {
        IERC20(underlying).safeTransfer(agreement.beneficiary, agreement.underlyAmount);
      }
      balances[underlying] -= agreement.underlyAmount;
    }
  }

  function userAgreements(address user) external view returns (Agreement[] memory) {
    uint256 agreementLength = _userAgreements[user].length();
    Agreement[] memory _agreements = new Agreement[](agreementLength);
    for (uint256 i; i < agreementLength; ++i) {
      _agreements[i] = agreements[_userAgreements[user].at(i)];
    }
    return _agreements;
  }

  function freezeAgreement(uint256 agreementId) external onlyEmergencyAdmin {
    agreements[agreementId].isFrozen = true;
    emit AgreementFrozen(agreementId, true);
  }

  function unfreezeAgreement(uint256 agreementId) external onlyAdmin {
    agreements[agreementId].isFrozen = false;
    emit AgreementFrozen(agreementId, false);
  }

  function freeze() external onlyEmergencyAdmin {
    frozen = true;
    emit TimeLockFrozen(true);
  }

  function unfreeze() external onlyAdmin {
    frozen = false;
    emit TimeLockFrozen(false);
  }
}
