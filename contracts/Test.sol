pragma solidity >=0.8.2 <0.9.0;

import './Exponential/ExponentialNoErrorNew.sol';

interface GasBoundCaller {
  function gasBoundCall(address _to, uint256 _maxTotalGas, bytes calldata _data) external returns (bytes memory);
}

contract Test is ExponentialNoErrorNew {
  event UsedGas(uint256 gasUsed, uint256 pubdataGasSpent, uint256 gasBefore, uint256 gasAfter);

  error FailedWith(bytes reason);

  address gasBoundCaller;

  constructor(address _gasBoundCaller) {
    gasBoundCaller = _gasBoundCaller;
  }

  function setGasBoundCaller(address _gasBoundCaller) external {
    gasBoundCaller = _gasBoundCaller;
  }

  function getBlockNumber() public view returns (uint256) {
    return block.number;
  }

  // function mul(uint256 a, uint256 b) public view returns (uint256, uint256) {
  //   Exp memory aexp = Exp({mantissa: a});
  //   uint256 r1 = mul_(aexp, b).mantissa;
  //   uint256 r2 = (a * b) / expScale;
  //   return (r1, r2);
  // }

  // function mulTruncate(uint256 a, uint256 b) public view returns (uint256, uint256) {
  //   Exp memory aexp = Exp({mantissa: a});
  //   uint256 r1 = mul_ScalarTruncate(aexp, b);
  //   uint256 r2 = (a * b) / expScale;
  //   return (r1, r2);
  // }

  function doTransferOut(address payable to, uint256 amount, uint256 maxTotalGas) public {
    /* Send the Ether, with minimal gas and revert on failure */
    // to.transfer(amount);

    uint256 computeGasBefore = gasleft();

    (bool success, bytes memory returnData) = address(gasBoundCaller).call{value: amount, gas: maxTotalGas}(
      abi.encodeWithSelector(GasBoundCaller.gasBoundCall.selector, to, maxTotalGas, new bytes(0))
    );
    if (!success) {
      revert FailedWith(returnData);
    }

    uint256 pubdataGasSpent;
    if (success) {
      (returnData, pubdataGasSpent) = abi.decode(returnData, (bytes, uint256));
    } else {
      // `returnData` is fully equal to the returndata, while `pubdataGasSpent` is equal to 0
    }

    uint256 computeGasAfter = gasleft();

    // This is the total gas that the subcall made the transaction to be charged for
    uint256 totalGasConsumed = computeGasBefore - computeGasAfter + pubdataGasSpent;

    uint256 gasUsed = computeGasBefore - computeGasAfter;

    emit UsedGas(gasUsed, pubdataGasSpent, computeGasBefore, computeGasAfter);
  }

  function rescue(address payable to, uint256 amount) external {
    address(to).call{value: amount}(new bytes(0));
  }

  function doTransferOutWithCall(address payable to, uint256 amount, uint256 maxTotalGas) public {
    /* Send the Ether, with minimal gas and revert on failure */
    // to.transfer(amount);

    uint256 computeGasBefore = gasleft();

    (bool success, bytes memory returnData) = address(to).call{value: amount, gas: maxTotalGas}(new bytes(0));
    if (!success) {
      revert FailedWith(returnData);
    }

    uint256 computeGasAfter = gasleft();

    // This is the total gas that the subcall made the transaction to be charged for
    uint256 totalGasConsumed = computeGasBefore - computeGasAfter;

    emit UsedGas(totalGasConsumed, 0, computeGasBefore, computeGasAfter);
  }

  /**
   * @notice Send Ether to CEther to mint
   */
  receive() external payable {}
}
