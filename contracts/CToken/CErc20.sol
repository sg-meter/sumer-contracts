// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './CToken.sol';
import '../Interfaces/ICErc20.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '../Interfaces/ITimelock.sol';
import '../Interfaces/IEIP712.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';
import {SafeTransferLib} from 'solmate/src/utils/SafeTransferLib.sol';

/**
 * @title Compound's CErc20 Contract
 * @notice CTokens which wrap an EIP-20 underlying
 * @author Compound
 */
contract CErc20 is CToken, ICErc20, Initializable {
  using SafeTransferLib for ERC20;

  constructor() {
    _disableInitializers();
  }

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
   */
  function initialize(
    address underlying_,
    address comptroller_,
    address interestRateModel_,
    uint256 initialExchangeRateMantissa_,
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    address payable admin_
  ) public virtual initializer {
    // CToken initialize does the bulk of the work
    CToken.init(comptroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_, admin_);

    // Set underlying and sanity check it
    if (underlying_ == address(0)) {
      revert InvalidAddress();
    }
    underlying = underlying_;
  }

  /*** User Interface ***/

  /**
   * @notice Sender supplies assets into the market and receives cTokens in exchange
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param mintAmount The amount of the underlying asset to supply
   */
  function mint(uint256 mintAmount) external virtual {
    mintInternal(mintAmount);
  }

  /**
   * @notice Sender redeems cTokens in exchange for the underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemTokens The number of cTokens to redeem into underlying
   */
  function redeem(uint256 redeemTokens) external virtual {
    redeemInternal(redeemTokens);
  }

  /**
   * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemAmount The amount of underlying to redeem
   */
  function redeemUnderlying(uint256 redeemAmount) external virtual {
    redeemUnderlyingInternal(redeemAmount);
  }

  /**
   * @notice Sender borrows assets from the protocol to their own address
   * @param borrowAmount The amount of the underlying asset to borrow
   */
  function borrow(uint256 borrowAmount) external virtual {
    borrowInternal(borrowAmount);
  }

  /**
   * @notice Sender repays their own borrow
   * @param repayAmount The amount to repay
   */
  function repayBorrow(uint256 repayAmount) external virtual {
    repayBorrowInternal(repayAmount);
  }

  /**
   * @notice Sender repays a borrow belonging to borrower
   * @param borrower the account with the debt being paid off
   * @param repayAmount The amount to repay
   */
  function repayBorrowBehalf(address borrower, uint256 repayAmount) external virtual {
    repayBorrowBehalfInternal(borrower, repayAmount);
  }

  /**
   * @notice The sender liquidates the borrowers collateral.
   *  The collateral seized is transferred to the liquidator.
   * @param borrower The borrower of this cToken to be liquidated
   * @param repayAmount The amount of the underlying borrowed asset to repay
   * @param cTokenCollateral The market in which to seize collateral from the borrower
   */
  function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral) external virtual {
    liquidateBorrowInternal(borrower, repayAmount, cTokenCollateral);
  }

  /**
   * @notice A public function to sweep accidental ERC-20 transfers to this contract. Tokens are sent to admin (timelock)
   * @param token The address of the ERC-20 token to sweep
   */
  function sweepToken(ERC20 token) external virtual override onlyAdmin {
    if (address(token) == underlying) {
      revert CantSweepUnderlying();
    }
    uint256 underlyingBalanceBefore = ERC20(underlying).balanceOf(address(this));
    uint256 balance = token.balanceOf(address(this));
    token.safeTransfer(admin, balance);
    uint256 underlyingBalanceAfter = ERC20(underlying).balanceOf(address(this));
    if (underlyingBalanceBefore != underlyingBalanceAfter) {
      revert UnderlyingBalanceError();
    }
  }

  /**
   * @notice The sender adds to reserves.
   * @param addAmount The amount fo underlying token to add as reserves
   */
  function _addReserves(uint256 addAmount) external virtual {
    return _addReservesInternal(addAmount);
  }

  /*** Safe Token ***/

  /**
   * @notice Gets balance of this contract in terms of the underlying
   * @dev This excludes the value of the current message, if any
   * @return The quantity of underlying tokens owned by this contract
   */
  function getCashPrior() internal view virtual override returns (uint256) {
    // ICToken token = ICToken(underlying);
    // return token.balanceOf(address(this));
    return underlyingBalance;
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
  function doTransferIn(address from, uint256 amount) internal virtual override returns (uint256) {
    ERC20 token = ERC20(underlying);
    uint256 balanceBefore = token.balanceOf(address(this));
    token.safeTransferFrom(from, address(this), amount);

    // Calculate the amount that was *actually* transferred
    uint256 balanceAfter = token.balanceOf(address(this));
    if (balanceAfter < balanceBefore) {
      revert TokenTransferInFailed();
    }
    uint256 finalAmount = balanceAfter - balanceBefore;
    underlyingBalance += finalAmount;
    return finalAmount; // underflow already checked above, just subtract
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
  function doTransferOut(address payable to, uint256 amount) internal virtual override {
    ERC20 token = ERC20(underlying);
    token.safeTransfer(to, amount);
    underlyingBalance -= amount;
  }

  function transferToTimelock(bool isBorrow, address to, uint256 underlyAmount) internal virtual override {
    address timelock = IComptroller(comptroller).timelock();
    bytes memory data = abi.encodeWithSignature('consumeValue(uint256)', underlyAmount);
    (bool success, ) = timelock.call(data);
    if (success) {
      // ITimelock(timelock).consumeValue(underlyAmount);
      doTransferOut(payable(to), underlyAmount);
    } else {
      doTransferOut(payable(timelock), underlyAmount);
      ITimelock(timelock).createAgreement(
        isBorrow ? ITimelock.TimeLockActionType.BORROW : ITimelock.TimeLockActionType.REDEEM,
        underlyAmount,
        to
      );
    }
  }

  /**
   * @notice Sender supplies assets into the market and receives cTokens in exchange
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param mintAmount The amount of the underlying asset to supply
   */
  function mintWithPermit(uint256 mintAmount, uint256 deadline, bytes memory signature) external {
    IEIP712(underlying).permit(msg.sender, address(this), mintAmount, deadline, signature);
    mintInternal(mintAmount);
  }

  /**
   * @notice Sender repays their own borrow
   * @param repayAmount The amount to repay
   */
  function repayBorrowWithPermit(uint256 repayAmount, uint256 deadline, bytes memory signature) external {
    IEIP712(underlying).permit(msg.sender, address(this), repayAmount, deadline, signature);
    repayBorrowInternal(repayAmount);
  }

  function isCToken() public pure virtual override returns (bool) {
    return true;
  }
  function isCEther() external pure virtual override returns (bool) {
    return false;
  }
  function tokenType() external pure virtual returns (CTokenType) {
    return CTokenType.CErc20;
  }
}
