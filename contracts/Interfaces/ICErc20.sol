// SPDX-License-Identifier: MIT
import {ERC20} from 'solmate/src/tokens/ERC20.sol';
pragma solidity ^0.8.19;

interface ICErc20 {
  /*** User Interface ***/

  function mint(uint256 mintAmount) external;

  function redeem(uint256 redeemTokens) external;

  function redeemUnderlying(uint256 redeemAmount) external;

  function borrow(uint256 borrowAmount) external;

  function repayBorrow(uint256 repayAmount) external;

  function repayBorrowBehalf(address borrower, uint256 repayAmount) external;

  function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral) external;

  function sweepToken(ERC20 token) external;

  /*** Admin Functions ***/

  function _addReserves(uint256 addAmount) external;
}
