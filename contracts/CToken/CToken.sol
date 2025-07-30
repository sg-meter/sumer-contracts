// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import '../Interfaces/IComptroller.sol';
import '../Interfaces/IPriceOracle.sol';
import '../Interfaces/IInterestRateModel.sol';
import './CTokenStorage.sol';
import '../Exponential/ExponentialNoErrorNew.sol';
import '../Comptroller/LiquityMath.sol';
import '../SumerErrors.sol';

/**
 * @title Compound's CToken Contract
 * @notice Abstract base for CTokens
 * @author Compound
 */
abstract contract CToken is CTokenStorage, ExponentialNoErrorNew, SumerErrors {
  /*** Market Events ***/

  enum CTokenType {
    CEther,
    CErc20,
    CSuErc20,
    CInfraredVault
  }

  /**
   * @notice Event emitted when interest is accrued
   */
  event AccrueInterest(uint256 cashPrior, uint256 interestAccumulated, uint256 borrowIndex, uint256 totalBorrows);

  /**
   * @notice Event emitted when tokens are minted
   */
  event Mint(address minter, uint256 mintAmount, uint256 mintTokens);

  /**
   * @notice Event emitted when tokens are redeemed
   */
  event Redeem(address redeemer, uint256 redeemAmount, uint256 redeemTokens);

  /**
   * @notice Event emitted when underlying is borrowed
   */
  event Borrow(address borrower, uint256 borrowAmount, uint256 accountBorrows, uint256 totalBorrows);

  /**
   * @notice Event emitted when a borrow is repaid
   */
  event RepayBorrow(address payer, address borrower, uint256 repayAmount, uint256 accountBorrows, uint256 totalBorrows);

  /**
   * @notice Event emitted when a borrow is liquidated
   */
  event LiquidateBorrow(
    address liquidator,
    address borrower,
    uint256 repayAmount,
    address cTokenCollateral,
    uint256 seizeTokens
  );

  /*** Admin Events ***/

  /**
   * @notice Event emitted when pendingAdmin is changed
   */
  event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

  /**
   * @notice Event emitted when pendingAdmin is accepted, which means admin is updated
   */
  event NewAdmin(address oldAdmin, address newAdmin);

  /**
   * @notice Event emitted when comptroller is changed
   */
  event NewComptroller(address oldComptroller, address newComptroller);

  /**
   * @notice Event emitted when interestRateModel is changed
   */
  event NewMarketInterestRateModel(address oldInterestRateModel, address newInterestRateModel);

  /**
   * @notice Event emitted when the reserve factor is changed
   */
  event NewReserveFactor(uint256 oldReserveFactorMantissa, uint256 newReserveFactorMantissa);

  /**
   * @notice Event emitted when the reserves are added
   */
  event ReservesAdded(address benefactor, uint256 addAmount, uint256 newTotalReserves);

  /**
   * @notice Event emitted when the reserves are reduced
   */
  event ReservesReduced(address admin, uint256 reduceAmount, uint256 newTotalReserves);

  /**
   * @notice EIP20 Transfer event
   */
  event Transfer(address indexed from, address indexed to, uint256 amount);

  /**
   * @notice EIP20 Approval event
   */
  event Approval(address indexed owner, address indexed spender, uint256 amount);

  event NewDiscountRate(uint256 oldDiscountRateMantissa, uint256 newDiscountRateMantissa);

  event RedeemFaceValue(
    address indexed redeemer,
    address indexed provider,
    uint256 repayAmount,
    address seizeToken,
    uint256 seizeAmount, // user seize amount + protocol seize amount
    uint256 redemptionRateMantissa
  );

  modifier onlyAdmin() {
    // Check caller is admin
    if (msg.sender != admin) {
      revert OnlyAdmin();
    }
    _;
  }

  /**
   * @notice Initialize the money market
   * @param comptroller_ The address of the Comptroller
   * @param interestRateModel_ The address of the interest rate model
   * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
   * @param name_ EIP-20 name of this token
   * @param symbol_ EIP-20 symbol of this token
   * @param decimals_ EIP-20 decimal precision of this token
   */
  function init(
    address comptroller_,
    address interestRateModel_,
    uint256 initialExchangeRateMantissa_,
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    address payable _admin
  ) internal {
    admin = _admin;
    if (accrualBlockTimestamp != 0 || borrowIndex != 0) {
      revert MarketCanOnlyInitializeOnce(); // market may only be initialized once
    }

    // Set initial exchange rate
    initialExchangeRateMantissa = initialExchangeRateMantissa_;
    if (initialExchangeRateMantissa <= 0) {
      revert InvalidExchangeRate();
    } // initial exchange rate must be greater than zero

    discountRateMantissa = 1e18; // default to be 100%
    reserveFactorMantissa = 1e17; // default to be 10%
    // Set the comptroller
    // Set market's comptroller to newComptroller
    comptroller = comptroller_;

    // Emit NewComptroller(oldComptroller, newComptroller)
    emit NewComptroller(address(0), comptroller_);

    // Initialize block number and borrow index (block number mocks depend on comptroller being set)
    accrualBlockTimestamp = getBlockTimestamp();
    borrowIndex = 1e18;

    // Set the interest rate model (depends on block number / borrow index)
    interestRateModel = interestRateModel_;
    emit NewMarketInterestRateModel(address(0), interestRateModel_);

    name = name_;
    symbol = symbol_;
    decimals = decimals_;

    // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
    _notEntered = true;
  }

  /**
   * @notice Transfer `tokens` tokens from `src` to `dst` by `spender`
   * @dev Called by both `transfer` and `transferFrom` internally
   * @param spender The address of the account performing the transfer
   * @param src The address of the source account
   * @param dst The address of the destination account
   * @param tokens The number of tokens to transfer
   * @return Whether or not the transfer succeeded
   */
  function transferTokens(address spender, address src, address dst, uint256 tokens) internal returns (uint256) {
    /* Fail if transfer not allowed */
    IComptroller(comptroller).transferAllowed(address(this), src, dst, tokens);

    /* Do not allow self-transfers */
    if (src == dst) {
      revert TransferNotAllowed();
    }

    /* Get the allowance, infinite for the account owner */
    uint256 startingAllowance = 0;
    if (spender == src) {
      startingAllowance = ~uint256(0);
    } else {
      startingAllowance = transferAllowances[src][spender];
    }

    /* Do the calculations, checking for {under,over}flow */
    uint allowanceNew = startingAllowance - tokens;
    uint srcTokensNew = accountTokens[src] - tokens;
    uint dstTokensNew = accountTokens[dst] + tokens;

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    accountTokens[src] = srcTokensNew;
    accountTokens[dst] = dstTokensNew;

    /* Eat some of the allowance (if necessary) */
    if (startingAllowance != ~uint256(0)) {
      transferAllowances[src][spender] = allowanceNew;
    }

    /* We emit a Transfer event */
    emit Transfer(src, dst, tokens);

    // unused function
    // comptroller.transferVerify(address(this), src, dst, tokens);

    return uint256(0);
  }

  /**
   * @notice Transfer `amount` tokens from `msg.sender` to `dst`
   * @param dst The address of the destination account
   * @param amount The number of tokens to transfer
   * @return Whether or not the transfer succeeded
   */
  function transfer(address dst, uint256 amount) external virtual override nonReentrant returns (bool) {
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
  ) external virtual override nonReentrant returns (bool) {
    return transferTokens(msg.sender, src, dst, amount) == uint256(0);
  }

  /**
   * @notice Approve `spender` to transfer up to `amount` from `src`
   * @dev This will overwrite the approval amount for `spender`
   *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
   * @param spender The address of the account which may transfer tokens
   * @param amount The number of tokens that are approved (-1 means infinite)
   * @return Whether or not the approval succeeded
   */
  function approve(address spender, uint256 amount) external override returns (bool) {
    address src = msg.sender;
    transferAllowances[src][spender] = amount;
    emit Approval(src, spender, amount);
    return true;
  }

  /**
   * @notice Get the current allowance from `owner` for `spender`
   * @param owner The address of the account which owns the tokens to be spent
   * @param spender The address of the account which may transfer tokens
   * @return The number of tokens allowed to be spent (-1 means infinite)
   */
  function allowance(address owner, address spender) external view override returns (uint256) {
    return transferAllowances[owner][spender];
  }

  /**
   * @notice Get the token balance of the `owner`
   * @param owner The address of the account to query
   * @return The number of tokens owned by `owner`
   */
  function balanceOf(address owner) external view override returns (uint256) {
    return accountTokens[owner];
  }

  /**
   * @notice Get the underlying balance of the `owner`
   * @dev This also accrues interest in a transaction
   * @param owner The address of the account to query
   * @return The amount of underlying owned by `owner`
   */
  function balanceOfUnderlying(address owner) external override returns (uint256) {
    Exp memory exchangeRate = Exp({mantissa: exchangeRateCurrent()});
    return mul_ScalarTruncate(exchangeRate, accountTokens[owner]);
  }

  /**
   * @notice Get a snapshot of the account's balances, and the cached exchange rate
   * @dev This is used by comptroller to more efficiently perform liquidity checks.
   * @param account Address of the account to snapshot
   * @return (possible error, token balance, borrow balance, exchange rate mantissa)
   */
  function getAccountSnapshot(address account) external view override returns (uint256, uint256, uint256, uint256) {
    return (
      accountTokens[account],
      borrowBalanceStoredInternal(account),
      exchangeRateStoredInternal(),
      discountRateMantissa
    );
  }

  /**
   * @dev Function to simply retrieve block number
   *  This exists mainly for inheriting test contracts to stub this result.
   */
  function getBlockTimestamp() internal view returns (uint256) {
    return block.timestamp;
  }

  /**
   * @notice Returns the current per-block borrow interest rate for this cToken
   * @return The borrow interest rate per block, scaled by 1e18
   */
  function borrowRatePerBlock() external view override returns (uint256) {
    return IInterestRateModel(interestRateModel).getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
  }

  /**
   * @notice Returns the current per-block supply interest rate for this cToken
   * @return The supply interest rate per block, scaled by 1e18
   */
  function supplyRatePerBlock() external view override returns (uint256) {
    return
      IInterestRateModel(interestRateModel).getSupplyRate(
        getCashPrior(),
        totalBorrows,
        totalReserves,
        reserveFactorMantissa
      );
  }

  /**
   * @notice Returns the current total borrows plus accrued interest
   * @return The total borrows with interest
   */
  function totalBorrowsCurrent() external override nonReentrant returns (uint256) {
    accrueInterest();
    return totalBorrows;
  }

  /**
   * @notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
   * @param account The address whose balance should be calculated after updating borrowIndex
   * @return The calculated balance
   */
  function borrowBalanceCurrent(address account) external override nonReentrant returns (uint256) {
    accrueInterest();
    return borrowBalanceStored(account);
  }

  /**
   * @notice Return the borrow balance of account based on stored data
   * @param account The address whose balance should be calculated
   * @return The calculated balance
   */
  function borrowBalanceStored(address account) public view override returns (uint256) {
    return borrowBalanceStoredInternal(account);
  }

  /**
   * @notice Return the borrow balance of account based on stored data
   * @param account The address whose balance should be calculated
   * @return (error code, the calculated balance or 0 if error code is non-zero)
   */
  function borrowBalanceStoredInternal(address account) internal view returns (uint256) {
    /* Get borrowBalance and borrowIndex */
    BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

    /* If borrowBalance = 0 then borrowIndex is likely also 0.
     * Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
     */
    if (borrowSnapshot.principal == 0) {
      return 0;
    }

    /* Calculate new borrow balance using the interest index:
     *  recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
     */
    uint principalTimesIndex = borrowSnapshot.principal * borrowIndex;
    return principalTimesIndex / borrowSnapshot.interestIndex;
  }

  /**
   * @notice Accrue interest then return the up-to-date exchange rate
   * @return Calculated exchange rate scaled by 1e18
   */
  function exchangeRateCurrent() public override nonReentrant returns (uint256) {
    accrueInterest();
    return exchangeRateStored();
  }

  /**
   * @notice Calculates the exchange rate from the underlying to the CToken
   * @dev This function does not accrue interest before calculating the exchange rate
   * @return Calculated exchange rate scaled by 1e18
   */
  function exchangeRateStored() public view override returns (uint256) {
    return exchangeRateStoredInternal();
  }

  /**
   * @notice Calculates the exchange rate from the underlying to the CToken
   * @dev This function does not accrue interest before calculating the exchange rate
   * @return (error code, calculated exchange rate scaled by 1e18)
   */
  function exchangeRateStoredInternal() internal view returns (uint256) {
    if (!isCToken()) {
      return initialExchangeRateMantissa;
    }

    uint _totalSupply = totalSupply;
    if (_totalSupply == 0) {
      /*
       * If there are no tokens minted:
       *  exchangeRate = initialExchangeRate
       */
      return initialExchangeRateMantissa;
    } else {
      /*
       * Otherwise:
       *  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
       */
      uint totalCash = getCashPrior();
      uint cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
      uint exchangeRate = (cashPlusBorrowsMinusReserves * expScale) / _totalSupply;

      return exchangeRate;
    }
  }

  /**
   * @notice Get cash balance of this cToken in the underlying asset
   * @return The quantity of underlying asset owned by this contract
   */
  function getCash() external view override returns (uint256) {
    return getCashPrior();
  }

  /**
   * @notice Applies accrued interest to total borrows and reserves
   * @dev This calculates interest accrued from the last checkpointed block
   *   up to the current block and writes new checkpoint to storage.
   */
  function accrueInterest() public virtual override {
    /* Remember the initial block number */
    uint256 currentBlockTimestamp = getBlockTimestamp();
    uint256 accrualBlockTimestampPrior = accrualBlockTimestamp;

    /* Short-circuit accumulating 0 interest */
    if (accrualBlockTimestampPrior == currentBlockTimestamp) {
      return;
    }

    /* Read the previous values out of storage */
    uint256 cashPrior = getCashPrior();
    uint256 borrowsPrior = totalBorrows;
    uint256 reservesPrior = totalReserves;
    uint256 borrowIndexPrior = borrowIndex;

    /* Calculate the current borrow interest rate */
    uint borrowRateMantissa = IInterestRateModel(interestRateModel).getBorrowRate(
      cashPrior,
      borrowsPrior,
      reservesPrior
    );
    // require(borrowRateMantissa <= borrowRateMaxMantissa, 'borrow rate is absurdly high');

    /* Calculate the number of blocks elapsed since the last accrual */
    uint blockDelta = currentBlockTimestamp - accrualBlockTimestampPrior;

    /*
     * Calculate the interest accumulated into borrows and reserves and the new index:
     *  simpleInterestFactor = borrowRate * blockDelta
     *  interestAccumulated = simpleInterestFactor * totalBorrows
     *  totalBorrowsNew = interestAccumulated + totalBorrows
     *  totalReservesNew = interestAccumulated * reserveFactor + totalReserves
     *  borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex
     */

    Exp memory simpleInterestFactor = mul_(Exp({mantissa: borrowRateMantissa}), blockDelta);
    uint interestAccumulated = mul_ScalarTruncate(simpleInterestFactor, borrowsPrior);
    uint totalBorrowsNew = interestAccumulated + borrowsPrior;
    uint totalReservesNew = mul_ScalarTruncateAddUInt(
      Exp({mantissa: reserveFactorMantissa}),
      interestAccumulated,
      reservesPrior
    );
    uint borrowIndexNew = mul_ScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write the previously calculated values into storage */
    accrualBlockTimestamp = currentBlockTimestamp;
    borrowIndex = borrowIndexNew;
    totalBorrows = totalBorrowsNew;
    totalReserves = totalReservesNew;

    /* We emit an AccrueInterest event */
    emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);
  }

  /**
   * @notice Sender supplies assets into the market and receives cTokens in exchange
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param mintAmount The amount of the underlying asset to supply
   */
  function mintInternal(uint256 mintAmount) internal virtual nonReentrant {
    accrueInterest();
    // mintFresh emits the actual Mint event if successful and logs on errors, so we don't need to
    mintFresh(msg.sender, mintAmount, true);
  }

  /**
   * @notice User supplies assets into the market and receives cTokens in exchange
   * @dev Assumes interest has already been accrued up to the current block
   * @param minter The address of the account which is supplying the assets
   * @param mintAmount The amount of the underlying asset to supply
   */
  function mintFresh(address minter, uint256 mintAmount, bool doTransfer) internal {
    Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});
    /* Fail if mint not allowed */
    IComptroller(comptroller).mintAllowed(address(this), minter, mintAmount, exchangeRate.mantissa);

    /* Verify market's block number equals current block number */
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert MintMarketNotFresh();
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /*
     *  We call `doTransferIn` for the minter and the mintAmount.
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  `doTransferIn` reverts if anything goes wrong, since we can't be sure if
     *  side-effects occurred. The function returns the amount actually transferred,
     *  in case of a fee. On success, the cToken holds an additional `actualMintAmount`
     *  of cash.
     */
    uint actualMintAmount;
    if (doTransfer) {
      actualMintAmount = doTransferIn(minter, mintAmount);
    } else {
      actualMintAmount = mintAmount;
      underlyingBalance += mintAmount;
    }

    if (actualMintAmount <= 1000) {
      revert NotEnoughUnderlyingForMint();
    }

    /*
     * We get the current exchange rate and calculate the number of cTokens to be minted:
     *  mintTokens = actualMintAmount / exchangeRate
     */

    uint mintTokens = div_(actualMintAmount, exchangeRate);

    if (mintTokens == 0) {
      revert MintTokensCantBeZero();
    }

    /*
     * We calculate the new total supply of cTokens and minter token balance, checking for overflow:
     *  totalSupplyNew = totalSupply + mintTokens
     *  accountTokensNew = accountTokens[minter] + mintTokens
     */
    totalSupply = totalSupply + mintTokens;
    accountTokens[minter] = accountTokens[minter] + mintTokens;

    /* We emit a Mint event, and a Transfer event */
    emit Mint(minter, actualMintAmount, mintTokens);
    emit Transfer(address(this), minter, mintTokens);

    /* We call the defense hook */
    // unused function
    // comptroller.mintVerify(address(this), minter, vars.actualMintAmount, vars.mintTokens);
  }

  /**
   * @notice Sender redeems cTokens in exchange for the underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemTokens The number of cTokens to redeem into underlying
   */
  function redeemInternal(uint256 redeemTokens) internal virtual nonReentrant {
    accrueInterest();
    // redeemFresh emits redeem-specific logs on errors, so we don't need to
    redeemFresh(payable(msg.sender), redeemTokens, 0, true);
  }

  /**
   * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemAmount The amount of underlying to receive from redeeming cTokens
   */
  function redeemUnderlyingInternal(uint256 redeemAmount) internal virtual nonReentrant {
    accrueInterest();
    // redeemFresh emits redeem-specific logs on errors, so we don't need to
    redeemFresh(payable(msg.sender), 0, redeemAmount, true);
  }

  /**
   * @notice User redeems cTokens in exchange for the underlying asset
   * @dev Assumes interest has already been accrued up to the current block
   * @param redeemer The address of the account which is redeeming the tokens
   * @param redeemTokensIn The number of cTokens to redeem into underlying (only one of redeemTokensIn or redeemAmountIn may be non-zero)
   * @param redeemAmountIn The number of underlying tokens to receive from redeeming cTokens (only one of redeemTokensIn or redeemAmountIn may be non-zero)
   * @param checkTimelock true=check timelock, false=direct transfer
   */
  function redeemFresh(
    address payable redeemer,
    uint256 redeemTokensIn,
    uint256 redeemAmountIn,
    bool checkTimelock
  ) internal {
    if (redeemTokensIn != 0 && redeemAmountIn != 0) {
      revert TokenInOrAmountInMustBeZero();
    }

    /* exchangeRate = invoke Exchange Rate Stored() */
    Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});

    uint redeemTokens;
    uint redeemAmount;
    /* If redeemTokensIn > 0: */
    if (redeemTokensIn > 0) {
      /*
       * We calculate the exchange rate and the amount of underlying to be redeemed:
       *  redeemTokens = redeemTokensIn
       *  redeemAmount = redeemTokensIn x exchangeRateCurrent
       */
      redeemTokens = redeemTokensIn;
      redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokensIn);
    } else {
      /*
       * We get the current exchange rate and calculate the amount to be redeemed:
       *  redeemTokens = redeemAmountIn / exchangeRate
       *  redeemAmount = redeemAmountIn
       */

      redeemTokens = div_(redeemAmountIn, exchangeRate);
      redeemAmount = redeemAmountIn;
    }

    // if not redeem all, set minimum threshold for redeemTokens and redeemAmount to 1000
    if (accountTokens[redeemer] != redeemTokens) {
      if (redeemTokens <= 1000) {
        revert NotEnoughRedeemTokens();
      }

      if (redeemAmount <= 1000) {
        revert NotEnoughRedeemAmount();
      }
    }

    /* Fail if redeem not allowed */
    IComptroller(comptroller).redeemAllowed(address(this), redeemer, redeemTokens, exchangeRate.mantissa);

    /* Verify market's block number equals current block number */
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert RedeemMarketNotFresh();
    }

    /* Fail gracefully if protocol has insufficient cash */
    if (isCToken() && (getCashPrior() < redeemAmount)) {
      revert RedeemTransferOutNotPossible();
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write previously calculated values into storage */
    totalSupply = totalSupply - redeemTokens;
    accountTokens[redeemer] = accountTokens[redeemer] - redeemTokens;

    if (accountTokens[redeemer] > 0 && accountTokens[redeemer] <= 1000) {
      revert NotEnoughUnderlyingAfterRedeem();
    }

    /*
     * We invoke doTransferOut for the redeemer and the redeemAmount.
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken has redeemAmount less of cash.
     *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
     */
    // doTransferOut(redeemer, vars.redeemAmount);
    if (checkTimelock) {
      transferToTimelock(false, redeemer, redeemAmount);
    } else {
      doTransferOut(redeemer, redeemAmount);
    }

    /* We emit a Transfer event, and a Redeem event */
    emit Transfer(redeemer, address(this), redeemTokens);
    emit Redeem(redeemer, redeemAmount, redeemTokens);

    /* We call the defense hook */
    IComptroller(comptroller).redeemVerify(address(this), redeemer, redeemAmount, redeemTokens);
  }

  /**
   * @notice Sender borrows assets from the protocol to their own address
   * @param borrowAmount The amount of the underlying asset to borrow
   */
  function borrowInternal(uint256 borrowAmount) internal nonReentrant {
    accrueInterest();
    // borrowFresh emits borrow-specific logs on errors, so we don't need to
    borrowFresh(payable(msg.sender), borrowAmount, true);
  }

  /**
   * @notice Users borrow assets from the protocol to their own address
   * @param borrowAmount The amount of the underlying asset to borrow
   */
  function borrowFresh(address payable borrower, uint256 borrowAmount, bool doTransfer) internal {
    /* Fail if borrow not allowed */
    IComptroller(comptroller).borrowAllowed(address(this), borrower, borrowAmount);

    /* Verify market's block number equals current block number */
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert BorrowMarketNotFresh();
    }

    /* Fail gracefully if protocol has insufficient underlying cash */
    if (isCToken() && (getCashPrior() < borrowAmount)) {
      revert BorrowCashNotAvailable();
    }

    /*
     * We calculate the new borrower and total borrow balances, failing on overflow:
     *  accountBorrowsNew = accountBorrows + borrowAmount
     *  totalBorrowsNew = totalBorrows + borrowAmount
     */
    uint accountBorrowsPrev = borrowBalanceStoredInternal(borrower);
    uint accountBorrowsNew = accountBorrowsPrev + borrowAmount;
    uint totalBorrowsNew = totalBorrows + borrowAmount;

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write the previously calculated values into storage */
    accountBorrows[borrower].principal = accountBorrowsNew;
    accountBorrows[borrower].interestIndex = borrowIndex;
    totalBorrows = totalBorrowsNew;

    /*
     * We invoke doTransferOut for the borrower and the borrowAmount.
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken borrowAmount less of cash.
     *  doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
     */
    // doTransferOut(borrower, borrowAmount);

    if (doTransfer) {
      transferToTimelock(true, borrower, borrowAmount);
    } else {
      underlyingBalance -= borrowAmount;
    }

    /* We emit a Borrow event */
    emit Borrow(borrower, borrowAmount, accountBorrowsNew, totalBorrowsNew);

    /* We call the defense hook */
    IComptroller(comptroller).borrowVerify(borrower, borrowAmount);
  }

  /**
   * @notice Sender repays their own borrow
   * @param repayAmount The amount to repay
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function repayBorrowInternal(uint256 repayAmount) internal nonReentrant returns (uint256) {
    accrueInterest();
    // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
    return repayBorrowFresh(msg.sender, msg.sender, repayAmount);
  }

  /**
   * @notice Sender repays a borrow belonging to borrower
   * @param borrower the account with the debt being paid off
   * @param repayAmount The amount to repay
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function repayBorrowBehalfInternal(address borrower, uint256 repayAmount) internal nonReentrant returns (uint256) {
    accrueInterest();
    // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
    return repayBorrowFresh(msg.sender, borrower, repayAmount);
  }

  /**
   * @notice Borrows are repaid by another user (possibly the borrower).
   * @param payer the account paying off the borrow
   * @param borrower the account with the debt being paid off
   * @param repayAmount the amount of underlying tokens being returned
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function repayBorrowFresh(address payer, address borrower, uint256 repayAmount) internal returns (uint256) {
    /* Fail if repayBorrow not allowed */
    IComptroller(comptroller).repayBorrowAllowed(address(this), payer, borrower, repayAmount);

    /* Verify market's block number equals current block number */
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert RepayBorrowMarketNotFresh();
    }

    /* We remember the original borrowerIndex for verification purposes */
    // uint256 borrowerIndex = accountBorrows[borrower].interestIndex;

    /* We fetch the amount the borrower owes, with accumulated interest */
    uint accountBorrowsPrev = borrowBalanceStoredInternal(borrower);

    /* If repayAmount == -1, repayAmount = accountBorrows */
    uint repayAmountFinal = LiquityMath._min(repayAmount, accountBorrowsPrev);

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /*
     * We call doTransferIn for the payer and the repayAmount
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken holds an additional repayAmount of cash.
     *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
     *   it returns the amount actually transferred, in case of a fee.
     */
    uint actualRepayAmount = doTransferIn(payer, repayAmountFinal);

    /*
     * We calculate the new borrower and total borrow balances, failing on underflow:
     *  accountBorrowsNew = accountBorrows - actualRepayAmount
     *  totalBorrowsNew = totalBorrows - actualRepayAmount
     */
    uint accountBorrowsNew = accountBorrowsPrev - actualRepayAmount;
    uint totalBorrowsNew = totalBorrows - actualRepayAmount;

    /* We write the previously calculated values into storage */
    accountBorrows[borrower].principal = accountBorrowsNew;
    accountBorrows[borrower].interestIndex = borrowIndex;
    totalBorrows = totalBorrowsNew;

    /* We emit a RepayBorrow event */
    emit RepayBorrow(payer, borrower, actualRepayAmount, accountBorrowsNew, totalBorrowsNew);

    /* We call the defense hook */
    IComptroller(comptroller).repayBorrowVerify(address(this), payer, borrower, actualRepayAmount, borrowIndex);

    return actualRepayAmount;
  }

  /**
   * @notice The sender liquidates the borrowers collateral.
   *  The collateral seized is transferred to the liquidator.
   * @param borrower The borrower of this cToken to be liquidated
   * @param cTokenCollateral The market in which to seize collateral from the borrower
   * @param repayAmount The amount of the underlying borrowed asset to repay
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function liquidateBorrowInternal(
    address borrower,
    uint256 repayAmount,
    address cTokenCollateral
  ) internal nonReentrant returns (uint256) {
    accrueInterest();
    ICToken(cTokenCollateral).accrueInterest();

    // liquidateBorrowFresh emits borrow-specific logs on errors, so we don't need to
    return liquidateBorrowFresh(msg.sender, borrower, repayAmount, cTokenCollateral);
  }

  /**
   * @notice The liquidator liquidates the borrowers collateral.
   *  The collateral seized is transferred to the liquidator.
   * @param borrower The borrower of this cToken to be liquidated
   * @param liquidator The address repaying the borrow and seizing collateral
   * @param cTokenCollateral The market in which to seize collateral from the borrower
   * @param repayAmount The amount of the underlying borrowed asset to repay
   * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
   */
  function liquidateBorrowFresh(
    address liquidator,
    address borrower,
    uint256 repayAmount,
    address cTokenCollateral
  ) internal returns (uint256) {
    /* Fail if liquidate not allowed */
    IComptroller(comptroller).liquidateBorrowAllowed(
      address(this),
      address(cTokenCollateral),
      liquidator,
      borrower,
      repayAmount
    );

    /* Verify market's block number equals current block number */
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert LiquidateMarketNotFresh();
    }

    /* Verify cTokenCollateral market's block number equals current block number */
    if (ICToken(cTokenCollateral).accrualBlockTimestamp() != getBlockTimestamp()) {
      revert LiquidateCollateralMarketNotFresh();
    }

    /* Fail if borrower = liquidator */
    if (borrower == liquidator) {
      revert LiquidateBorrow_LiquidatorIsBorrower();
    }

    /* Fail if repayAmount = 0 */
    if (repayAmount == 0) {
      revert LiquidateBorrow_RepayAmountIsZero();
    }

    if (repayAmount == ~uint256(0)) {
      revert LiquidateBorrow_RepayAmountIsMax();
    }

    /* Fail if repayBorrow fails */
    uint256 actualRepayAmount = repayBorrowFresh(liquidator, borrower, repayAmount);

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We calculate the number of collateral tokens that will be seized */
    (uint256 seizeTokens, uint256 seizeProfitTokens) = liquidateCalculateSeizeTokens(
      cTokenCollateral,
      actualRepayAmount
    );

    /* Revert if borrower collateral token balance < seizeTokens */
    if (ICToken(cTokenCollateral).balanceOf(borrower) < seizeTokens) {
      revert LiquidateBorrow_SeizeTooMuch();
    }

    // If this is also the collateral, run seizeInternal to avoid re-entrancy, otherwise make an external call
    if (cTokenCollateral == address(this)) {
      seizeInternal(address(this), liquidator, borrower, seizeTokens, seizeProfitTokens, false, uint256(0));
    } else {
      ICToken(cTokenCollateral).seize(liquidator, borrower, seizeTokens, seizeProfitTokens, false, uint256(0));
    }

    /* We emit a LiquidateBorrow event */
    emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(cTokenCollateral), seizeTokens);

    /* We call the defense hook */
    // unused function
    IComptroller(comptroller).liquidateBorrowVerify(
      address(this),
      address(cTokenCollateral),
      liquidator,
      borrower,
      actualRepayAmount,
      seizeTokens
    );

    return actualRepayAmount;
  }

  /**
   * @notice Transfers collateral tokens (this market) to the liquidator.
   * @dev Will fail unless called by another cToken during the process of liquidation.
   *  Its absolutely critical to use msg.sender as the borrowed cToken and not a parameter.
   * @param liquidator The account receiving seized collateral
   * @param borrower The account having collateral seized
   * @param seizeTokens The number of cTokens to seize in total (including profit)
   * @param seizeProfitTokens The number of cToken to seize as profit
   */
  function seize(
    address liquidator,
    address borrower,
    uint256 seizeTokens,
    uint256 seizeProfitTokens,
    bool isRedemption,
    uint256 redemptionRateMantissa
  ) external override nonReentrant {
    if (redemptionRateMantissa <= 0) {
      redemptionRateMantissa = 0;
    }
    if (redemptionRateMantissa > expScale) {
      redemptionRateMantissa = expScale;
    }

    return
      seizeInternal(
        msg.sender,
        liquidator,
        borrower,
        seizeTokens,
        seizeProfitTokens,
        isRedemption,
        redemptionRateMantissa
      );
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
  ) internal virtual {
    /* Fail if seize not allowed */
    IComptroller(comptroller).seizeAllowed(address(this), seizerToken, liquidator, borrower, seizeTokens);

    /* Fail if borrower = liquidator */
    if (borrower == liquidator) {
      revert Seize_LiquidatorIsBorrower();
    }

    /*
     * We calculate the new borrower and liquidator token balances, failing on underflow/overflow:
     *  borrowerTokensNew = accountTokens[borrower] - seizeTokens
     *  liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
     */
    uint protocolSeizeTokens;
    if (isRedemption) {
      // redemption: protocol seize = total seize * redemptionRate
      protocolSeizeTokens = mul_(seizeTokens, Exp({mantissa: redemptionRateMantissa}));
    } else {
      // liquidation: protocol seize = profit * liquidatiionShare 30%
      protocolSeizeTokens = mul_(seizeProfitTokens, Exp({mantissa: protocolSeizeShareMantissa}));
    }
    if (seizeTokens < protocolSeizeTokens) {
      revert NotEnoughForSeize();
    }

    uint liquidatorSeizeTokens = seizeTokens - protocolSeizeTokens;
    Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});
    uint protocolSeizeAmount = mul_ScalarTruncate(exchangeRate, protocolSeizeTokens);
    uint totalReservesNew = totalReserves + protocolSeizeAmount;

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /* We write the previously calculated values into storage */
    totalReserves = totalReservesNew;
    totalSupply = totalSupply - protocolSeizeTokens;
    accountTokens[borrower] = accountTokens[borrower] - seizeTokens;
    accountTokens[liquidator] = accountTokens[liquidator] + liquidatorSeizeTokens;

    /* Emit a Transfer event */
    emit Transfer(borrower, liquidator, liquidatorSeizeTokens);
    emit Transfer(borrower, address(this), protocolSeizeTokens);
    emit ReservesAdded(address(this), protocolSeizeAmount, totalReservesNew);

    /* We call the defense hook */
    // unused function
    // comptroller.seizeVerify(address(this), seizerToken, liquidator, borrower, seizeTokens);

    if (isRedemption) {
      redeemFresh(payable(liquidator), liquidatorSeizeTokens, uint256(0), true);
    } else {
      redeemFresh(payable(liquidator), liquidatorSeizeTokens, uint256(0), false);
    }
  }

  /*** Admin Functions ***/

  /**
   * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
   * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
   * @param newPendingAdmin New pending admin.
   */
  function _setPendingAdmin(address payable newPendingAdmin) external override onlyAdmin {
    // Save current value, if any, for inclusion in log
    address oldPendingAdmin = pendingAdmin;

    // Store pendingAdmin with value newPendingAdmin
    if (newPendingAdmin == address(0)) {
      revert InvalidAddress();
    } // Address is Zero
    pendingAdmin = newPendingAdmin;

    // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
    emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
  }

  /**
   * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
   * @dev Admin function for pending admin to accept role and update admin
   */
  function _acceptAdmin() external override {
    // Check caller is pendingAdmin and pendingAdmin ≠ address(0)
    if (msg.sender != pendingAdmin || msg.sender == address(0)) {
      revert OnlyPendingAdmin();
    }

    // Save current values for inclusion in log
    address oldAdmin = admin;
    address oldPendingAdmin = pendingAdmin;

    // Store admin with value pendingAdmin
    admin = pendingAdmin;

    // Clear the pending value
    pendingAdmin = payable(0);

    emit NewAdmin(oldAdmin, admin);
    emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);
  }

  /**
   * @notice Sets a new comptroller for the market
   * @dev Admin function to set a new comptroller
   */
  function _setComptroller(address newComptroller) public override onlyAdmin {
    address oldComptroller = comptroller;
    // Ensure invoke comptroller.isComptroller() returns true
    if (!IComptroller(newComptroller).isComptroller()) {
      revert InvalidComptroller(); // market method returned false
    }

    // Set market's comptroller to newComptroller
    comptroller = newComptroller;

    // Emit NewComptroller(oldComptroller, newComptroller)
    emit NewComptroller(oldComptroller, newComptroller);
  }

  /**
   * @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
   * @dev Admin function to accrue interest and set a new reserve factor
   */
  function _setReserveFactor(uint256 newReserveFactorMantissa) external override nonReentrant onlyAdmin {
    accrueInterest();
    // Verify market's block number equals current block number
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert SetReservesFactorMarketNotFresh();
    }

    // Check newReserveFactor ≤ maxReserveFactor
    if (newReserveFactorMantissa > RESERVE_FACTOR_MAX_MANTISSA) {
      revert InvalidReserveFactor();
    }

    uint256 oldReserveFactorMantissa = reserveFactorMantissa;
    reserveFactorMantissa = newReserveFactorMantissa;

    emit NewReserveFactor(oldReserveFactorMantissa, newReserveFactorMantissa);
  }

  /**
   * @notice Accrues interest and reduces reserves by transferring from msg.sender
   * @param addAmount Amount of addition to reserves
   */
  function _addReservesInternal(uint256 addAmount) internal nonReentrant {
    accrueInterest();
    // _addReservesFresh emits reserve-addition-specific logs on errors, so we don't need to.
    _addReservesFresh(addAmount);
  }

  /**
   * @notice Add reserves by transferring from caller
   * @dev Requires fresh interest accrual
   * @param addAmount Amount of addition to reserves
   * @return (uint, uint) An error code (0=success, otherwise a failure (see ErrorReporter.sol for details)) and the actual amount added, net token fees
   */
  function _addReservesFresh(uint256 addAmount) internal returns (uint256) {
    // totalReserves + actualAddAmount
    uint256 totalReservesNew;
    uint256 actualAddAmount;

    // We fail gracefully unless market's block number equals current block number
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert AddReservesMarketNotFresh();
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    /*
     * We call doTransferIn for the caller and the addAmount
     *  Note: The cToken must handle variations between ERC-20 and ETH underlying.
     *  On success, the cToken holds an additional addAmount of cash.
     *  doTransferIn reverts if anything goes wrong, since we can't be sure if side effects occurred.
     *  it returns the amount actually transferred, in case of a fee.
     */

    actualAddAmount = doTransferIn(msg.sender, addAmount);

    totalReservesNew = totalReserves + actualAddAmount;

    /* Revert on overflow */
    if (totalReservesNew < totalReserves) {
      revert AddReservesOverflow();
    }

    // Store reserves[n+1] = reserves[n] + actualAddAmount
    totalReserves = totalReservesNew;

    /* Emit NewReserves(admin, actualAddAmount, reserves[n+1]) */
    emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);

    /* Return (NO_ERROR, actualAddAmount) */
    return (actualAddAmount);
  }

  /**
   * @notice Accrues interest and reduces reserves by transferring to admin
   * @param reduceAmount Amount of reduction to reserves
   */
  function _reduceReserves(uint256 reduceAmount) external virtual {
    accrueInterest();
    // _reduceReservesFresh emits reserve-reduction-specific logs on errors, so we don't need to.
    _reduceReservesFresh(reduceAmount);
  }

  /**
   * @notice Reduces reserves by transferring to admin
   * @dev Requires fresh interest accrual
   * @param reduceAmount Amount of reduction to reserves
   */
  function _reduceReservesFresh(uint256 reduceAmount) internal onlyAdmin nonReentrant {
    // totalReserves - reduceAmount
    uint256 totalReservesNew;

    // We fail gracefully unless market's block number equals current block number
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert ReduceReservesMarketNotFresh();
    }

    // Fail gracefully if protocol has insufficient underlying cash
    if (getCashPrior() < reduceAmount) {
      revert ReduceReservesCashNotAvailable();
    }

    // Check reduceAmount ≤ reserves[n] (totalReserves)
    if (reduceAmount > totalReserves) {
      revert InvalidReduceAmount();
    }

    /////////////////////////
    // EFFECTS & INTERACTIONS
    // (No safe failures beyond this point)

    totalReservesNew = totalReserves - reduceAmount;

    // Store reserves[n+1] = reserves[n] - reduceAmount
    totalReserves = totalReservesNew;

    // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
    doTransferOut(admin, reduceAmount);

    emit ReservesReduced(admin, reduceAmount, totalReservesNew);
  }

  /**
   * @notice accrues interest and updates the interest rate model using _setInterestRateModelFresh
   * @dev Admin function to accrue interest and update the interest rate model
   * @param newInterestRateModel the new interest rate model to use
   */
  function _setInterestRateModel(address newInterestRateModel) external override onlyAdmin {
    accrueInterest();
    // Used to store old model for use in the event that is emitted on success
    address oldInterestRateModel;
    // We fail gracefully unless market's block number equals current block number
    if (accrualBlockTimestamp != getBlockTimestamp()) {
      revert SetInterestRateModelMarketNotFresh();
    }

    // Track the market's current interest rate model
    oldInterestRateModel = interestRateModel;

    // Ensure invoke newInterestRateModel.isInterestRateModel() returns true
    if (!IInterestRateModel(interestRateModel).isInterestRateModel()) {
      revert InvalidInterestRateModel();
    }

    // Set the interest rate model to newInterestRateModel
    interestRateModel = newInterestRateModel;

    // Emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel)
    emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);
  }

  function _syncUnderlyingBalance() external virtual onlyAdmin {
    underlyingBalance = ICToken(underlying).balanceOf(address(this));
  }

  /*** Safe Token ***/

  /**
   * @notice Gets balance of this contract in terms of the underlying
   * @dev This excludes the value of the current message, if any
   * @return The quantity of underlying owned by this contract
   */
  function getCashPrior() internal view virtual returns (uint256);

  /**
   * @dev Performs a transfer in, reverting upon failure. Returns the amount actually transferred to the protocol, in case of a fee.
   *  This may revert due to insufficient balance or insufficient allowance.
   */
  function doTransferIn(address from, uint256 amount) internal virtual returns (uint256);

  /**
   * @dev Performs a transfer out, ideally returning an explanatory error code upon failure rather than reverting.
   *  If caller has not called checked protocol's balance, may revert due to insufficient cash held in the contract.
   *  If caller has checked protocol's balance, and verified it is >= amount, this should not revert in normal conditions.
   */
  function doTransferOut(address payable to, uint256 amount) internal virtual;

  function transferToTimelock(bool isBorrow, address to, uint256 amount) internal virtual;

  /*** Reentrancy Guard ***/

  /**
   * @dev Prevents a contract from calling itself, directly or indirectly.
   */
  modifier nonReentrant() {
    if (!_notEntered) {
      revert Reentered();
    } // re-entered
    _notEntered = false;
    _;
    _notEntered = true; // get a gas-refund post-Istanbul
  }

  /**
   * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
   * @dev Used in liquidation (called in ICToken(cToken).liquidateBorrowFresh)
   * @param cTokenCollateral The address of the collateral cToken
   * @param actualRepayAmount The amount of cTokenBorrowed underlying to convert into cTokenCollateral tokens
   * @return ( number of cTokenCollateral tokens to be seized in a liquidation, number of cTokenCollateral tokens to be seized as profit in a liquidation)
   */
  function liquidateCalculateSeizeTokens(
    address cTokenCollateral,
    uint256 actualRepayAmount
  ) public view returns (uint256, uint256) {
    (bool repayListed, uint8 repayTokenGroupId, ) = IComptroller(comptroller).markets(address(this));
    if (!repayListed) {
      revert RepayTokenNotListed();
    }
    (bool seizeListed, uint8 seizeTokenGroupId, ) = IComptroller(comptroller).markets(cTokenCollateral);
    if (!seizeListed) {
      revert SeizeTokenNotListed();
    }

    LiquidationIncentive memory liquidationIncentive = IComptroller(comptroller).liquidationIncentive();

    // default is repaying heterogeneous assets
    uint256 liquidationIncentiveMantissa = uint256(liquidationIncentive.heteroPercent) * percentScale;
    if (repayTokenGroupId == seizeTokenGroupId) {
      if (CToken(address(this)).isCToken() == false) {
        // repaying sutoken
        liquidationIncentiveMantissa = uint256(liquidationIncentive.sutokenPercent) * percentScale;
      } else {
        // repaying homogeneous assets
        liquidationIncentiveMantissa = uint256(liquidationIncentive.homoPercent) * percentScale;
      }
    }

    /* Read oracle prices for borrowed and collateral markets */
    uint256 priceBorrowedMantissa = IComptroller(comptroller).getUnderlyingPriceNormalized(address(this));
    uint256 priceCollateralMantissa = IComptroller(comptroller).getUnderlyingPriceNormalized(cTokenCollateral);
    /*
     * Get the exchange rate and calculate the number of collateral tokens to seize:
     *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
     *  seizeTokens = seizeAmount / exchangeRate
     *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
     */
    uint256 exchangeRateMantissa = ICToken(cTokenCollateral).exchangeRateStored(); // Note: reverts on error

    Exp memory numerator = mul_(
      Exp({mantissa: liquidationIncentiveMantissa + expScale}),
      Exp({mantissa: priceBorrowedMantissa})
    );
    Exp memory profitNumerator = mul_(
      Exp({mantissa: liquidationIncentiveMantissa}),
      Exp({mantissa: priceBorrowedMantissa})
    );
    Exp memory denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));

    Exp memory ratio = div_(numerator, denominator);
    Exp memory profitRatio = div_(profitNumerator, denominator);

    uint256 seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);
    uint256 seizeProfitTokens = mul_ScalarTruncate(profitRatio, actualRepayAmount);

    return (seizeTokens, seizeProfitTokens);
  }

  function _setDiscountRate(uint256 discountRateMantissa_) external onlyAdmin returns (uint256) {
    uint256 oldDiscountRateMantissa_ = discountRateMantissa;
    discountRateMantissa = discountRateMantissa_;
    emit NewDiscountRate(oldDiscountRateMantissa_, discountRateMantissa_);
    return discountRateMantissa;
  }

  function borrowAndDepositBack(address borrower, uint256 borrowAmount) external nonReentrant {
    // only allowed to be called from su token
    if (CToken(msg.sender).isCToken()) {
      revert NotSuToken();
    }
    // only cToken has this function
    if (!isCToken()) {
      revert NotCToken();
    }
    if (!IComptroller(comptroller).isListed(msg.sender)) {
      revert MarketNotListed();
    }
    if (!IComptroller(comptroller).isListed(address(this))) {
      revert MarketNotListed();
    }
    borrowAndDepositBackInternal(payable(borrower), borrowAmount);
  }

  /**
   * @notice Sender borrows assets from the protocol and deposit all of them back to the protocol
   * @param borrowAmount The amount of the underlying asset to borrow and deposit
   */
  function borrowAndDepositBackInternal(address payable borrower, uint256 borrowAmount) internal virtual {
    accrueInterest();
    borrowFresh(borrower, borrowAmount, false);
    mintFresh(borrower, borrowAmount, false);
  }

  function isCToken() public pure virtual returns (bool) {
    return true;
  }
  function isCEther() external pure virtual returns (bool) {
    return false;
  }
}
