pragma solidity >=0.8.2 <0.9.0;

import './Exponential/ExponentialNoErrorNew.sol';

contract Test is ExponentialNoErrorNew {
  function getBlockNumber() public view returns (uint256) {
    return block.number;
  }

  function mul(uint256 a, uint256 b) public view returns (uint256, uint256) {
    Exp memory aexp = Exp({mantissa: a});
    uint256 r1 = mul_(aexp, b).mantissa;
    uint256 r2 = (a * b) / expScale;
    return (r1, r2);
  }

  function mulTruncate(uint256 a, uint256 b) public view returns (uint256, uint256) {
    Exp memory aexp = Exp({mantissa: a});
    uint256 r1 = mul_ScalarTruncate(aexp, b);
    uint256 r2 = (a * b) / expScale;
    return (r1, r2);
  }
}
