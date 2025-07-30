// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {CErc20, CToken} from '../CToken/CErc20.sol';
import {IInfraredVault} from './IInfraredVault.sol';
import {SafeTransferLib} from 'solmate/src/utils/SafeTransferLib.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';
import '@balancer-labs/v2-pool-utils/contracts/lib/VaultReentrancyLib.sol';

interface IPool {
  function getVault() external view returns (address);
}
/**
 * @title
 * @notice CTokens which wrap an infrared vault
 * @author Meter.io
 */
contract CInfraredVault is CErc20 {
  using SafeTransferLib for ERC20;

  struct UserShare {
    uint256 amount;
    uint256 lastUpdateTime;
  }

  struct UserPoint {
    uint256 amount;
    uint256 pointsIndex;
  }

  error CantSweepRewardToken();
  error UnderlyingMismatch();

  /**
   * @notice Emitted when rewards are claimed
   * @param user The address of the user claiming the reward
   * @param rewardsToken The address of the reward token
   * @param reward The amount of rewards claimed
   */
  event UserRewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);

  event UpdatePoints(uint256 timestamp, uint256 totalPoints, address account, uint256 _userPoints);

  /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

  /**
   * @notice The token that users stake to earn rewards
   * @dev This is the base token that users deposit into the contract
   */
  IInfraredVault internal infraredVault;

  /**
   * @notice Tracks the reward per token paid to each user for each reward token
   * @dev Maps user address to reward token address to amount already paid
   * Used to calculate new rewards since last claim
   */
  mapping(address => UserShare) internal _userPoints;

  /**
   * @notice The total shares of staked tokens
   */
  uint256 internal _totalPoints;

  uint256 internal _deprecated; // originally was _protocolPoints

  /**
   * @notice The timestamp for last global calculation
   */
  uint256 internal _lastUpdateTime;

  IVault internal _deprecated2; // originally was balancerVault

  mapping(address => uint256) public protocolRewards;

  /*//////////////////////////////////////////////////////////////
                        MODIFIERS
    //////////////////////////////////////////////////////////////*/

  /**
   * @notice Updates the reward for the given account before executing the
   * function body.
   * @param account address The account to update the reward for.
   */
  modifier updatePoints(address account) {
    (_userPoints[account].amount, _totalPoints, _lastUpdateTime) = _calcPoints(account);

    _userPoints[account].lastUpdateTime = _lastUpdateTime;

    emit UpdatePoints(_lastUpdateTime, _totalPoints, account, _userPoints[account].amount);
    _;
  }

  modifier whenNotInVaultContext() {
    _ensureNotInVaultContext();
    _;
  }

  /**
   * @dev Reverts if called in the middle of a Vault operation; has no effect otherwise.
   */
  function _ensureNotInVaultContext() private view {
    bytes memory data = abi.encodeCall(IPool.getVault, ());
    (bool success, bytes memory returnData) = underlying.staticcall(data);
    if (success) {
      // underlying is Balancer BPT
      VaultReentrancyLib.ensureNotInVaultContext(IVault(IPool(underlying).getVault()));
    } else {
      // underlying is Kodiak Island
    }
  }

  function _calcPoints(
    address account
  ) internal view returns (uint256 newUserPoints, uint256 newTotalPoints, uint256 newLastUpdateTime) {
    uint256 timestamp = block.timestamp;
    uint256 globalTimeDiff = timestamp - _lastUpdateTime;

    // set defaults
    newTotalPoints = _totalPoints;
    newLastUpdateTime = _lastUpdateTime;

    if (globalTimeDiff > 0) {
      newTotalPoints = _totalPoints + totalSupply * globalTimeDiff;
      newLastUpdateTime = timestamp;
    }

    uint256 userTimeDiff = timestamp - _userPoints[account].lastUpdateTime;

    // set defaults
    newUserPoints = _userPoints[account].amount;

    if (userTimeDiff > 0 && _userPoints[account].lastUpdateTime != 0) {
      newUserPoints = _userPoints[account].amount + userTimeDiff * accountTokens[account];
    }
  }

  /*//////////////////////////////////////////////////////////////
                               READS
    //////////////////////////////////////////////////////////////*/

  function getRewardTokens() internal view virtual returns (address[] memory) {
    return infraredVault.getAllRewardTokens();
  }

  function shareOf(address account) public view returns (uint256 _share) {
    (uint256 latestUserPoints, uint256 latestTotalPoints, ) = _calcPoints(account);

    if (latestTotalPoints == 0) {
      return 0;
    }

    return (latestUserPoints * percentScale) / latestTotalPoints;
  }

  function points(address account) external view returns (uint256, uint256, uint256) {
    return (_lastUpdateTime, _totalPoints, _userPoints[account].amount);
  }

  function earned(address account) external view returns (IInfraredVault.UserReward[] memory) {
    uint256 sharePercent = shareOf(account);

    IInfraredVault.UserReward[] memory rewards = infraredVault.getAllRewardsForUser(address(this));
    for (uint i = 0; i < rewards.length; i++) {
      uint256 balance = ERC20(rewards[i].token).balanceOf(address(this));
      uint256 actualReward = (rewards[i].amount * (expScale - reserveFactorMantissa)) / expScale;
      uint256 userAmount = (sharePercent * (balance + actualReward - protocolRewards[rewards[i].token])) / percentScale;
      rewards[i].amount = userAmount;
    }
    return rewards;
  }

  function _claimInfraredRewards() internal {
    IInfraredVault.UserReward[] memory pending = infraredVault.getAllRewardsForUser(address(this));

    for (uint256 i; i < pending.length; i++) {
      IInfraredVault.UserReward memory reward = pending[i];
      protocolRewards[reward.token] =
        protocolRewards[reward.token] +
        (reward.amount * reserveFactorMantissa) /
        expScale;
    }

    // collect all the rewards up till now
    infraredVault.getRewardForUser(address(this));
  }

  function _claimAllInternal() internal {
    _claimInfraredRewards();
    address user = msg.sender;
    uint256 pointsClaimed = _userPoints[user].amount;

    if (_totalPoints < pointsClaimed) {
      return;
    }

    uint256 totalPointsBefore = _totalPoints;

    _userPoints[user].amount = 0;
    _totalPoints = _totalPoints - pointsClaimed;

    address[] memory rewardTokens = getRewardTokens();
    uint256 len = rewardTokens.length;
    for (uint256 i; i < len; i++) {
      ERC20 token = ERC20(rewardTokens[i]);
      uint256 totalRewards = token.balanceOf(address(this)) - protocolRewards[rewardTokens[i]];
      uint256 reward = (pointsClaimed * totalRewards) / totalPointsBefore;
      if (reward > 0) {
        token.safeTransfer(user, reward);
        emit UserRewardPaid(user, address(token), reward);
      }
    }
  }
  /*//////////////////////////////////////////////////////////////
                            WRITES
    //////////////////////////////////////////////////////////////*/

  function claimAll() external nonReentrant updatePoints(msg.sender) {
    _claimAllInternal();
  }

  function claimProtocolRewards(address _to) external nonReentrant updatePoints(address(0)) onlyAdmin {
    _claimInfraredRewards();
    address[] memory rewardTokens = getRewardTokens();
    for (uint256 i; i < rewardTokens.length; i++) {
      ERC20 token = ERC20(rewardTokens[i]);
      if (protocolRewards[rewardTokens[i]] > 0) {
        token.safeTransfer(_to, protocolRewards[rewardTokens[i]]);
        protocolRewards[rewardTokens[i]] = 0;
      }
    }
  }

  /*//////////////////////////////////////////////////////////////
                            CTOKEN FUNCS
    //////////////////////////////////////////////////////////////*/

  /**
   * @notice Initialize the new money market
   * @param underlying_ The address of the underlying asset
   * @param comptroller_ The address of the Comptroller
   * @param interestRateModel_ The address of the interest rate model
   * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
   * @param name_ ERC-20 name of this token
   * @param symbol_ ERC-20 symbol of this token
   * @param decimals_ ERC-20 decimal precision of this token
   * @param admin_ Address of the administrator of this token
   * @param infraredVault_ Address of infrared vault that takes underlying as staking token
   */
  function initialize(
    address underlying_,
    address comptroller_,
    address interestRateModel_,
    uint256 initialExchangeRateMantissa_,
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    address payable admin_,
    address infraredVault_
  ) public initializer {
    infraredVault = IInfraredVault(infraredVault_);
    _lastUpdateTime = block.timestamp;

    // address underlying_ = infraredVault.stakingToken();
    if (infraredVault.stakingToken() != underlying_) {
      revert UnderlyingMismatch();
    }
    // CToken initialize does the bulk of the work
    CToken.init(comptroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_, admin_);

    // Set underlying and sanity check it
    // if (underlying_ == address(0)) {
    // revert InvalidAddress();
    // }
    underlying = underlying_;
  }

  /**
   * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
   *      This will revert due to insufficient balance or insufficient allowance.
   *      This function returns the actual amount received,
   *      which may be less than `amount` if there is a fee attached to the transfer.
   *
   *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
   *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
   */
  function doTransferIn(
    address from,
    uint256 amount
  ) internal virtual override whenNotInVaultContext returns (uint256) {
    uint256 finalAmount = super.doTransferIn(from, amount);

    ERC20 underlyingToken = ERC20(underlying);
    // uint256 balance = underlyingToken.balanceOf(address(this));
    underlyingToken.safeApprove(address(infraredVault), finalAmount);
    infraredVault.stake(finalAmount);

    return finalAmount;
  }

  /**
   * @dev Similar to EIP20 transfer, except it handles a False success from `transfer` and returns an explanatory
   *      error code rather than reverting. If caller has not called checked protocol's balance, this may revert due to
   *      insufficient cash held in this contract. If caller has checked protocol's balance prior to this call, and verified
   *      it is >= amount, this should not revert in normal conditions.
   *
   *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
   *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
   */
  function doTransferOut(address payable to, uint256 amount) internal virtual override whenNotInVaultContext {
    infraredVault.withdraw(amount);

    super.doTransferOut(to, amount);
  }

  /*** User Interface ***/

  /**
   * @notice Sender supplies assets into the market and receives cTokens in exchange
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param mintAmount The amount of the underlying asset to supply
   */
  function mintInternal(uint256 mintAmount) internal override nonReentrant updatePoints(msg.sender) {
    accrueInterest();
    // mintFresh emits the actual Mint event if successful and logs on errors, so we don't need to
    mintFresh(msg.sender, mintAmount, true);
  }

  /**
   * @notice Sender redeems cTokens in exchange for the underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemTokens The number of cTokens to redeem into underlying
   */
  function redeemInternal(uint256 redeemTokens) internal override nonReentrant updatePoints(msg.sender) {
    accrueInterest();
    // redeemFresh emits redeem-specific logs on errors, so we don't need to
    redeemFresh(payable(msg.sender), redeemTokens, 0, true);
    _claimAllInternal();
  }

  /**
   * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemAmount The amount of underlying to receive from redeeming cTokens
   */
  function redeemUnderlyingInternal(uint256 redeemAmount) internal override nonReentrant updatePoints(msg.sender) {
    accrueInterest();
    // redeemFresh emits redeem-specific logs on errors, so we don't need to
    redeemFresh(payable(msg.sender), 0, redeemAmount, true);
    _claimAllInternal();
  }

  /**
   * @notice Transfers collateral tokens (this market) to the liquidator.
   * @dev Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another CToken.
   *  Its absolutely critical to use msg.sender as the seizer cToken and not a parameter.
   * @param seizerToken The contract seizing the collateral (i.e. borrowed cToken)
   * @param liquidator The account receiving seized collateral
   * @param borrower The account having collateral seized
   * @param seizeTokens The number of cTokens to seize
   */
  function seizeInternal(
    address seizerToken,
    address liquidator,
    address borrower,
    uint256 seizeTokens,
    uint256 seizeProfitTokens,
    bool isRedemption,
    uint256 redemptionRateMantissa
  ) internal virtual override updatePoints(liquidator) updatePoints(borrower) {
    super.seizeInternal(
      seizerToken,
      liquidator,
      borrower,
      seizeTokens,
      seizeProfitTokens,
      isRedemption,
      redemptionRateMantissa
    );
  }

  /**
   * @notice Sender borrows assets from the protocol and deposit all of them back to the protocol
   * @param borrowAmount The amount of the underlying asset to borrow and deposit
   */
  function borrowAndDepositBackInternal(
    address payable borrower,
    uint256 borrowAmount
  ) internal virtual override updatePoints(borrower) {
    accrueInterest();
    borrowFresh(borrower, borrowAmount, false);
    mintFresh(borrower, borrowAmount, false);
  }

  /**
   * @notice Transfer `amount` tokens from `msg.sender` to `dst`
   * @param dst The address of the destination account
   * @param amount The number of tokens to transfer
   * @return Whether or not the transfer succeeded
   */
  function transfer(
    address dst,
    uint256 amount
  ) external override nonReentrant updatePoints(msg.sender) updatePoints(dst) returns (bool) {
    return transferTokens(msg.sender, msg.sender, dst, amount) == uint256(0);
  }

  /**
   * @notice Transfer `amount` tokens from `src` to `dst`
   * @param src The address of the source account
   * @param dst The address of the destination account
   * @param amount The number of tokens to transfer
   * @return Whether or not the transfer succeeded
   */
  function transferFrom(
    address src,
    address dst,
    uint256 amount
  ) external virtual override nonReentrant updatePoints(src) updatePoints(dst) returns (bool) {
    return transferTokens(msg.sender, src, dst, amount) == uint256(0);
  }

  /**
   * @notice A public function to sweep accidental ERC-20 transfers to this contract. Tokens are sent to admin (timelock)
   * @param token The address of the ERC-20 token to sweep
   */
  function sweepToken(ERC20 token) external override onlyAdmin {
    if (address(token) == underlying) {
      revert CantSweepUnderlying();
    }
    address[] memory rewardTokens = getRewardTokens();
    for (uint256 i = 0; i < rewardTokens.length; i++) {
      if (rewardTokens[i] == address(token)) {
        revert CantSweepRewardToken();
      }
    }

    token.safeTransfer(admin, token.balanceOf(address(this)));
  }

  function tokenType() external pure virtual override returns (CTokenType) {
    return CTokenType.CInfraredVault;
  }

  function _syncUnderlyingBalance() external virtual override onlyAdmin {}
}
