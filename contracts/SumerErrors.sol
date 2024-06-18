// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

/// @title Multicall2 - Aggregate results from multiple read-only function calls
/// @author Michael Elliot <mike@makerdao.com>
/// @author Joshua Levine <joshua@makerdao.com>
/// @author Nick Johnson <arachnid@notdot.net>

contract SumerErrors {
  error PriceError();

  error RedemptionSignerNotInitialized();
  error NotEnoughForSeize();
  error NoRedemptionProvider();
  error MarketNotListed();
  error InsufficientShortfall();
  error TooMuchRepay();
  error OneOfRedeemTokensAndRedeemAmountMustBeZero();
  error InvalidMinSuBorrowValue();
  error BorrowValueMustBeLargerThanThreshold(uint256 usdThreshold);
  error ProtocolIsPaused();
  error MarketAlreadyListed();
  error InvalidAddress();
  error InvalidGroupId();
  error InvalidCloseFactor();
  error InvalidSuToken();
  error InvalidSignatureLength();
  error ExpiredSignature();
  error SenderMustBeCToken();
  error MintPaused();
  error BorrowPaused();
  error TransferPaused();
  error SeizePaused();
  error InsufficientCollateral();
  error GroupIdMismatch();
  error EitherAssetOrDebtMustBeZeroInGroup(
    uint8 groupId,
    uint256 cDepositVal,
    uint256 suDepositVal,
    uint256 cBorrowVal,
    uint256 suBorrowVal
  );
  error EitherAssetOrDebtMustBeZero();

  error OnlyAdminOrCapper();
  error OnlyAdminOrPauser();

  // general errors
  error OnlyAdmin();
  error OnlyPendingAdmin();
  error OnlyRedemptionManager();
  error OnlyListedCToken();
  error OnlyCToken();
  error UnderlyingBalanceError();
  error MarketCanOnlyInitializeOnce();
  error CantSweepUnderlying();
  error TokenTransferInFailed();
  error TokenTransferOutFailed();
  error TransferNotAllowed();
  error TokenInOrAmountInMustBeZero();
  error AddReservesOverflow();
  error ReduceReservesOverflow();
  error RedeemTransferOutNotPossible();
  error BorrowCashNotAvailable();
  error ReduceReservesCashNotAvailable();
  error InvalidDiscountRate();
  error InvalidExchangeRate();
  error InvalidReduceAmount();
  error InvalidReserveFactor();
  error InvalidComptroller();
  error InvalidInterestRateModel();
  error InvalidAmount();
  error InvalidInput();
  error BorrowAndDepositBackFailed();
  error InvalidSignatureForRedeemFaceValue();

  error BorrowCapReached();
  error SupplyCapReached();
  error ComptrollerMismatch();

  error MintMarketNotFresh();
  error BorrowMarketNotFresh();
  error RepayBorrowMarketNotFresh();
  error RedeemMarketNotFresh();
  error LiquidateMarketNotFresh();
  error LiquidateCollateralMarketNotFresh();
  error ReduceReservesMarketNotFresh();
  error SetInterestRateModelMarketNotFresh();
  error AddReservesMarketNotFresh();
  error SetReservesFactorMarketNotFresh();
  error CantExitMarketWithNonZeroBorrowBalance();

  // error
  error NotCToken();
  error NotSuToken();

  // error in liquidateBorrow
  error LiquidateBorrow_RepayAmountIsZero();
  error LiquidateBorrow_RepayAmountIsMax();
  error LiquidateBorrow_LiquidatorIsBorrower();
  error LiquidateBorrow_SeizeTooMuch();

  // error in seize
  error Seize_LiquidatorIsBorrower();

  // error in protected mint
  error ProtectedMint_OnlyAllowAssetsInTheSameGroup();

  error RedemptionSeizeTooMuch();

  error MinDelayNotReached();

  error NotLiquidatableYet();
}
