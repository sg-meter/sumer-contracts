// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import '../Interfaces/IEIP20NonStandard.sol';
import './CErc20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';

/**
 * @title Compound's suErc20 Contract
 * @notice CTokens which wrap an EIP-20 underlying
 * @author Compound
 */
contract suErc20 is CErc20 {
  /**
   * @notice Gets balance of this contract in terms of the underlying
   * @dev This excludes the value of the current message, if any
   * @return The quantity of underlying tokens owned by this contract
   */
  // function getCashPrior() internal view virtual override returns (uint256) {
  //   // ICToken token = ICToken(underlying);
  //   // return token.balanceOf(address(this));
  //   return underlyingBalance;
  // }

  /**
   * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
   *      This will revert due to insufficient balance or insufficient allowance.
   *      This function returns the actual amount received,
   *      which may be less than `amount` if there is a fee attached to the transfer.
   *
   *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
   *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
   */
  function doTransferIn(address from, uint256 amount) internal override returns (uint256) {
    IEIP20NonStandard token = IEIP20NonStandard(underlying);
    token.burnFrom(from, amount);

    bool success;
    assembly {
      switch returndatasize()
      case 0 {
        // This is a non-standard ERC-20
        success := not(0) // set success to true
      }
      case 32 {
        // This is a compliant ERC-20
        returndatacopy(0, 0, 32)
        success := mload(0) // Set `success = returndata` of external call
      }
      default {
        // This is an excessively non-compliant ERC-20, revert.
        revert(0, 0)
      }
    }
    if (!success) {
      revert TokenTransferInFailed();
    }

    // Calculate the amount that was *actually* transferred
    return amount;
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
  function doTransferOut(address payable to, uint256 amount) internal override {
    IEIP20NonStandard token = IEIP20NonStandard(underlying);
    token.mint(to, amount);

    bool success;
    assembly {
      switch returndatasize()
      case 0 {
        // This is a non-standard ERC-20
        success := not(0) // set success to true
      }
      case 32 {
        // This is a compliant ERC-20
        returndatacopy(0, 0, 32)
        success := mload(0) // Set `success = returndata` of external call
      }
      default {
        // This is an excessively non-compliant ERC-20, revert.
        revert(0, 0)
      }
    }
    if (!success) {
      revert TokenTransferOutFailed();
    }
  }

  function executeRedemption(
    address redeemer,
    address provider,
    uint256 repayAmount,
    address cTokenCollateral,
    uint256 seizeAmount,
    uint256 redemptionRateMantissa
  ) external nonReentrant {
    if (msg.sender != IComptroller(comptroller).redemptionManager()) {
      revert OnlyRedemptionManager();
    }

    if (this.isCToken()) {
      revert NotSuToken();
    }

    uint256 cExRateMantissa = CErc20(cTokenCollateral).exchangeRateStored();
    uint256 cPriceMantissa = IComptroller(comptroller).getUnderlyingPriceNormalized(cTokenCollateral);
    uint256 csuPriceMantissa = IComptroller(comptroller).getUnderlyingPriceNormalized(address(this));

    accrueInterest();
    ICToken(cTokenCollateral).accrueInterest();

    uint256 seizeVal = (((seizeAmount * cExRateMantissa) / expScale) * (cPriceMantissa)) / expScale;
    uint256 repayVal = (csuPriceMantissa * repayAmount) / expScale;
    if (seizeVal > repayVal) {
      revert RedemptionSeizeTooMuch();
    }

    repayBorrowFresh(redeemer, provider, repayAmount);
    ICToken(cTokenCollateral).seize(redeemer, provider, seizeAmount, uint256(0), true, redemptionRateMantissa);

    emit RedeemFaceValue(redeemer, provider, repayAmount, cTokenCollateral, seizeAmount, redemptionRateMantissa);
  }

  function protectedMint(
    address cTokenCollateral,
    uint256 cBorrowAmount,
    uint256 suBorrowAmount
  ) external nonReentrant {
    if (!CToken(cTokenCollateral).isCToken()) {
      revert NotCToken();
    }

    (, uint8 suGroupId, ) = IComptroller(comptroller).markets(address(this));
    (, uint8 cGroupId, ) = IComptroller(comptroller).markets(cTokenCollateral);
    if (suGroupId != cGroupId) {
      revert ProtectedMint_OnlyAllowAssetsInTheSameGroup();
    }

    accrueInterest();

    if (cBorrowAmount <= 0) {
      revert InvalidAmount();
    }

    CToken(cTokenCollateral).borrowAndDepositBack(payable(msg.sender), cBorrowAmount);

    return borrowFresh(payable(msg.sender), suBorrowAmount, true);
  }

  function isCToken() public pure override returns (bool) {
    return false;
  }
  function isCEther() external pure override returns (bool) {
    return false;
  }
  function tokenType() external pure virtual override returns (CTokenType) {
    return CTokenType.CSuErc20;
  }
}
