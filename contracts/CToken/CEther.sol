// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import './CToken.sol';
import '../Interfaces/ICErc20.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '../Interfaces/ITimelock.sol';
import '../Comptroller/LiquityMath.sol';

/**
 * @title Compound's CEther Contract
 * @notice CToken which wraps Ether
 * @author Compound
 */
contract CEther is CToken, Initializable {
  constructor() {
    _disableInitializers();
  }

  /**
   * @notice Construct a new CEther money market
   * @param comptroller_ The address of the Comptroller
   * @param interestRateModel_ The address of the interest rate model
   * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
   * @param name_ ERC-20 name of this token
   * @param symbol_ ERC-20 symbol of this token
   * @param decimals_ ERC-20 decimal precision of this token
   * @param admin_ Address of the administrator of this token
   */
  function initialize(
    address comptroller_,
    address interestRateModel_,
    uint256 initialExchangeRateMantissa_,
    string memory name_,
    string memory symbol_,
    uint8 decimals_,
    address payable admin_
  ) public initializer {
    super.init(comptroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_, admin_);
  }

  function initializeVersion2() public virtual reinitializer(2) {}

  function _syncUnderlyingBalance() external override onlyAdmin {
    underlyingBalance = address(this).balance;
  }

  /*** User Interface ***/

  /**
   * @notice Sender supplies assets into the market and receives cTokens in exchange
   * @dev Reverts upon any failure
   */
  function mint() external payable {
    mintInternal(msg.value);
  }

  /**
   * @notice Sender redeems cTokens in exchange for the underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemTokens The number of cTokens to redeem into underlying
   */
  function redeem(uint256 redeemTokens) external {
    redeemInternal(redeemTokens);
  }

  /**
   * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
   * @dev Accrues interest whether or not the operation succeeds, unless reverted
   * @param redeemAmount The amount of underlying to redeem
   */
  function redeemUnderlying(uint256 redeemAmount) external {
    redeemUnderlyingInternal(redeemAmount);
  }

  /**
   * @notice Sender borrows assets from the protocol to their own address
   * @param borrowAmount The amount of the underlying asset to borrow
   */
  function borrow(uint256 borrowAmount) external {
    borrowInternal(borrowAmount);
  }

  /**
   * @notice Sender repays their own borrow
   * @dev Reverts upon any failure
   */
  function repayBorrow() external payable {
    repayBorrowInternal(msg.value);
  }

  /**
   * @notice Sender repays a borrow belonging to borrower
   * @dev Reverts upon any failure
   * @param borrower the account with the debt being paid off
   */
  function repayBorrowBehalf(address borrower) external payable {
    uint256 actualRepay = repayBorrowBehalfInternal(borrower, msg.value);
    if (actualRepay < msg.value) {
      (bool sent, ) = msg.sender.call{gas: 5300, value: msg.value - actualRepay}('');
      require(sent, 'refund failed');
    }
  }

  /**
   * @notice The sender liquidates the borrowers collateral.
   *  The collateral seized is transferred to the liquidator.
   * @dev Reverts upon any failure
   * @param borrower The borrower of this cToken to be liquidated
   * @param cTokenCollateral The market in which to seize collateral from the borrower
   */
  function liquidateBorrow(address borrower, address cTokenCollateral) external payable {
    liquidateBorrowInternal(borrower, msg.value, cTokenCollateral);
  }

  /**
   * @notice The sender adds to reserves.
   */
  function _addReserves() external payable {
    _addReservesInternal(msg.value);
  }

  /**
   * @notice Send Ether to CEther to mint
   */
  receive() external payable {
    mintInternal(msg.value);
  }

  /*** Safe Token ***/

  /**
   * @notice Gets balance of this contract in terms of Ether, before this message
   * @dev This excludes the value of the current message, if any
   * @return The quantity of Ether owned by this contract
   */
  function getCashPrior() internal view override returns (uint256) {
    // (MathError err, uint256 startingBalance) = address(this).balance.subUInt(msg.value);
    // require(err == MathError.NO_ERROR);
    // return startingBalance;
    return underlyingBalance;
  }

  /**
   * @notice Perform the actual transfer in, which is a no-op
   * @param from Address sending the Ether
   * @param amount Amount of Ether being sent
   * @return The actual amount of Ether transferred
   */
  function doTransferIn(address from, uint256 amount) internal override returns (uint256) {
    // Sanity checks
    require(msg.sender == from, 'sender mismatch');
    require(msg.value >= amount, 'value mismatch');
    underlyingBalance += amount;
    return amount;
  }

  function doTransferOut(address payable to, uint256 amount) internal override {
    underlyingBalance -= amount;
    /* Send the Ether, with minimal gas and revert on failure */
    // to.transfer(amount);
    (bool success, ) = to.call{gas: 5300, value: amount}('');
    require(success, 'unable to send value, recipient may have reverted');
  }

  function transferToTimelock(bool isBorrow, address to, uint256 underlyAmount) internal virtual override {
    address timelock = IComptroller(comptroller).timelock();
    (bool success, ) = timelock.call(abi.encodeWithSignature('consumeValue(uint256)', underlyAmount));

    if (success) {
      // if leaky bucket covers underlyAmount, release immediately
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

  function isCToken() public pure override returns (bool) {
    return true;
  }
  function isCEther() external pure override returns (bool) {
    return true;
  }
  function tokenType() external pure virtual returns (CTokenType) {
    return CTokenType.CEther;
  }
}
