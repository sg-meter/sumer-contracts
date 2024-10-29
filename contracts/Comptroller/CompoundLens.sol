// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import '../Interfaces/ICTokenExternal.sol';
import '../Interfaces/IPriceOracle.sol';
import '../Interfaces/IGovernorAlpha.sol';
import '../Interfaces/IComptroller.sol';
import '../Interfaces/IGovernorBravo.sol';
import '../Exponential/ExponentialNoErrorNew.sol';
import '../SumerErrors.sol';

contract CompoundLens is ExponentialNoErrorNew, SumerErrors {
  uint256 public constant percentScale = 1e14;
  struct CTokenMetadata {
    address cToken;
    uint256 exchangeRateCurrent;
    uint256 supplyRatePerBlock;
    uint256 borrowRatePerBlock;
    uint256 reserveFactorMantissa;
    uint256 totalBorrows;
    uint256 totalReserves;
    uint256 totalSupply;
    uint256 totalCash;
    bool isListed;
    // uint256 collateralFactorMantissa;
    address underlyingAssetAddress;
    uint256 cTokenDecimals;
    uint256 underlyingDecimals;
    bool isCToken;
    bool isCEther;
    uint256 borrowCap;
    uint256 depositCap;
    uint256 heteroLiquidationIncentive;
    uint256 homoLiquidationIncentive;
    uint256 sutokenLiquidationIncentive;
    uint8 groupId;
    uint256 intraRate;
    uint256 mintRate;
    uint256 interRate;
    uint256 discountRate;
    bool interMintAllowed;
  }

  struct GroupInfo {
    uint256 intraRate;
    uint256 mintRate;
    uint256 interRate;
  }

  function cTokenMetadata(ICToken cToken) public returns (CTokenMetadata memory) {
    IComptroller comptroller = IComptroller(address(cToken.comptroller()));

    // get underlying info
    address underlyingAssetAddress;
    uint256 underlyingDecimals;
    if (cToken.isCEther()) {
      underlyingAssetAddress = address(0);
      underlyingDecimals = 18;
    } else {
      underlyingAssetAddress = cToken.underlying();
      underlyingDecimals = ICToken(cToken.underlying()).decimals();
    }

    // get group info
    (bool isListed, uint8 assetGroupId, ) = comptroller.markets(address(cToken));
    CompactAssetGroup memory group = comptroller.assetGroup(assetGroupId);
    GroupInfo memory gi;
    if (cToken.isCToken()) {
      gi.intraRate = uint256(group.intraCRatePercent) * percentScale;
      gi.interRate = uint256(group.interCRatePercent) * percentScale;
      gi.mintRate = uint256(group.intraMintRatePercent) * percentScale;
    } else {
      gi.intraRate = uint256(group.intraSuRatePercent) * percentScale;
      gi.interRate = uint256(group.interSuRatePercent) * percentScale;
      gi.mintRate = uint256(group.intraSuRatePercent) * percentScale;
    }
    LiquidationIncentive memory liquidationIncentive = comptroller.liquidationIncentive();
    return
      CTokenMetadata({
        cToken: address(cToken),
        exchangeRateCurrent: cToken.exchangeRateCurrent(),
        supplyRatePerBlock: cToken.supplyRatePerBlock(),
        borrowRatePerBlock: cToken.borrowRatePerBlock(),
        reserveFactorMantissa: cToken.reserveFactorMantissa(),
        totalBorrows: cToken.totalBorrows(),
        totalReserves: cToken.totalReserves(),
        totalSupply: cToken.totalSupply(),
        totalCash: cToken.getCash(),
        isListed: isListed,
        underlyingAssetAddress: underlyingAssetAddress,
        cTokenDecimals: cToken.decimals(),
        underlyingDecimals: underlyingDecimals,
        isCToken: cToken.isCToken(),
        isCEther: cToken.isCEther(),
        borrowCap: comptroller.marketConfig(address(cToken)).borrowCap,
        depositCap: comptroller.marketConfig(address(cToken)).supplyCap,
        heteroLiquidationIncentive: uint256(liquidationIncentive.heteroPercent) * percentScale,
        homoLiquidationIncentive: uint256(liquidationIncentive.homoPercent) * percentScale,
        sutokenLiquidationIncentive: uint256(liquidationIncentive.sutokenPercent) * percentScale,
        groupId: assetGroupId,
        intraRate: gi.intraRate,
        interRate: gi.interRate,
        mintRate: gi.mintRate,
        discountRate: cToken.discountRateMantissa(),
        interMintAllowed: comptroller.interMintAllowed()
      });
  }

  function cTokenMetadataAll(ICToken[] calldata cTokens) external returns (CTokenMetadata[] memory) {
    uint256 cTokenCount = cTokens.length;
    CTokenMetadata[] memory res = new CTokenMetadata[](cTokenCount);
    for (uint256 i = 0; i < cTokenCount; i++) {
      res[i] = cTokenMetadata(cTokens[i]);
    }
    return res;
  }

  struct CTokenBalances {
    address cToken;
    bool isCToken;
    bool isCEther;
    uint256 balanceOf;
    uint256 borrowBalanceCurrent;
    uint256 balanceOfUnderlying;
    uint256 tokenBalance;
    uint256 tokenAllowance;
  }

  function cTokenBalances(ICToken cToken, address payable account) public returns (CTokenBalances memory) {
    uint256 balanceOf = cToken.balanceOf(account);
    uint256 borrowBalanceCurrent = cToken.borrowBalanceCurrent(account);
    uint256 balanceOfUnderlying = cToken.balanceOfUnderlying(account);
    uint256 tokenBalance;
    uint256 tokenAllowance;

    if (cToken.isCEther()) {
      tokenBalance = account.balance;
      tokenAllowance = account.balance;
    } else {
      ICToken underlying = ICToken(cToken.underlying());
      tokenBalance = underlying.balanceOf(account);
      tokenAllowance = underlying.allowance(account, address(cToken));
    }

    return
      CTokenBalances({
        cToken: address(cToken),
        isCToken: cToken.isCToken(),
        isCEther: cToken.isCEther(),
        balanceOf: balanceOf,
        borrowBalanceCurrent: borrowBalanceCurrent,
        balanceOfUnderlying: balanceOfUnderlying,
        tokenBalance: tokenBalance,
        tokenAllowance: tokenAllowance
      });
  }

  function cTokenBalancesAll(
    ICToken[] calldata cTokens,
    address payable account
  ) external returns (CTokenBalances[] memory) {
    uint256 cTokenCount = cTokens.length;
    CTokenBalances[] memory res = new CTokenBalances[](cTokenCount);
    for (uint256 i = 0; i < cTokenCount; i++) {
      res[i] = cTokenBalances(cTokens[i], account);
    }
    return res;
  }

  struct CTokenUnderlyingPrice {
    address cToken;
    uint256 underlyingPrice;
  }

  function cTokenUnderlyingPrice(ICToken cToken) public view returns (CTokenUnderlyingPrice memory) {
    IComptroller comptroller = IComptroller(address(cToken.comptroller()));
    IPriceOracle priceOracle = IPriceOracle(comptroller.oracle());

    return
      CTokenUnderlyingPrice({
        cToken: address(cToken),
        underlyingPrice: priceOracle.getUnderlyingPrice(address(cToken))
      });
  }

  function cTokenUnderlyingPriceAll(ICToken[] calldata cTokens) external view returns (CTokenUnderlyingPrice[] memory) {
    uint256 cTokenCount = cTokens.length;
    CTokenUnderlyingPrice[] memory res = new CTokenUnderlyingPrice[](cTokenCount);
    for (uint256 i = 0; i < cTokenCount; i++) {
      res[i] = cTokenUnderlyingPrice(cTokens[i]);
    }
    return res;
  }

  struct AccountLimits {
    address[] markets;
    uint256 liquidity;
    uint256 shortfall;
  }

  function getAccountLimits(IComptroller comptroller, address account) external view returns (AccountLimits memory) {
    (uint256 liquidity, uint256 shortfall) = comptroller.getHypotheticalAccountLiquidity(account, address(0), 0, 0);

    return AccountLimits({markets: comptroller.getAssetsIn(account), liquidity: liquidity, shortfall: shortfall});
  }

  struct GovReceipt {
    uint256 proposalId;
    bool hasVoted;
    bool support;
    uint96 votes;
  }

  function getGovReceipts(
    IGovernorAlpha governor,
    address voter,
    uint256[] memory proposalIds
  ) public view returns (GovReceipt[] memory) {
    uint256 proposalCount = proposalIds.length;
    GovReceipt[] memory res = new GovReceipt[](proposalCount);
    for (uint256 i = 0; i < proposalCount; i++) {
      IGovernorAlpha.Receipt memory receipt;

      (receipt.hasVoted, receipt.support, receipt.votes) = governor.getReceipt(proposalIds[i], voter);
      res[i] = GovReceipt({
        proposalId: proposalIds[i],
        hasVoted: receipt.hasVoted,
        support: receipt.support,
        votes: receipt.votes
      });
    }
    return res;
  }

  struct GovBravoReceipt {
    uint256 proposalId;
    bool hasVoted;
    uint8 support;
    uint96 votes;
  }

  function getGovBravoReceipts(
    IGovernorBravo governor,
    address voter,
    uint256[] memory proposalIds
  ) public view returns (GovBravoReceipt[] memory) {
    uint256 proposalCount = proposalIds.length;
    GovBravoReceipt[] memory res = new GovBravoReceipt[](proposalCount);
    for (uint256 i = 0; i < proposalCount; i++) {
      IGovernorBravo.Receipt memory receipt = governor.getReceipt(proposalIds[i], voter);
      res[i] = GovBravoReceipt({
        proposalId: proposalIds[i],
        hasVoted: receipt.hasVoted,
        support: receipt.support,
        votes: receipt.votes
      });
    }
    return res;
  }

  struct GovProposal {
    uint256 proposalId;
    address proposer;
    uint256 eta;
    address[] targets;
    uint256[] values;
    string[] signatures;
    bytes[] calldatas;
    uint256 startBlock;
    uint256 endBlock;
    uint256 forVotes;
    uint256 againstVotes;
    bool canceled;
    bool executed;
  }

  function setProposal(GovProposal memory res, IGovernorAlpha governor, uint256 proposalId) internal view {
    (
      ,
      address proposer,
      uint256 eta,
      uint256 startBlock,
      uint256 endBlock,
      uint256 forVotes,
      uint256 againstVotes,
      bool canceled,
      bool executed
    ) = governor.proposals(proposalId);
    res.proposalId = proposalId;
    res.proposer = proposer;
    res.eta = eta;
    res.startBlock = startBlock;
    res.endBlock = endBlock;
    res.forVotes = forVotes;
    res.againstVotes = againstVotes;
    res.canceled = canceled;
    res.executed = executed;
  }

  function getGovProposals(
    IGovernorAlpha governor,
    uint256[] calldata proposalIds
  ) external view returns (GovProposal[] memory) {
    GovProposal[] memory res = new GovProposal[](proposalIds.length);
    for (uint256 i = 0; i < proposalIds.length; i++) {
      (
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas
      ) = governor.getActions(proposalIds[i]);
      res[i] = GovProposal({
        proposalId: 0,
        proposer: address(0),
        eta: 0,
        targets: targets,
        values: values,
        signatures: signatures,
        calldatas: calldatas,
        startBlock: 0,
        endBlock: 0,
        forVotes: 0,
        againstVotes: 0,
        canceled: false,
        executed: false
      });
      setProposal(res[i], governor, proposalIds[i]);
    }
    return res;
  }

  struct GovBravoProposal {
    uint256 proposalId;
    address proposer;
    uint256 eta;
    address[] targets;
    uint256[] values;
    string[] signatures;
    bytes[] calldatas;
    uint256 startBlock;
    uint256 endBlock;
    uint256 forVotes;
    uint256 againstVotes;
    uint256 abstainVotes;
    bool canceled;
    bool executed;
  }

  function setBravoProposal(GovBravoProposal memory res, IGovernorBravo governor, uint256 proposalId) internal view {
    IGovernorBravo.Proposal memory p = governor.proposals(proposalId);

    res.proposalId = proposalId;
    res.proposer = p.proposer;
    res.eta = p.eta;
    res.startBlock = p.startBlock;
    res.endBlock = p.endBlock;
    res.forVotes = p.forVotes;
    res.againstVotes = p.againstVotes;
    res.abstainVotes = p.abstainVotes;
    res.canceled = p.canceled;
    res.executed = p.executed;
  }

  function getGovBravoProposals(
    IGovernorBravo governor,
    uint256[] calldata proposalIds
  ) external view returns (GovBravoProposal[] memory) {
    GovBravoProposal[] memory res = new GovBravoProposal[](proposalIds.length);
    for (uint256 i = 0; i < proposalIds.length; i++) {
      (
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas
      ) = governor.getActions(proposalIds[i]);
      res[i] = GovBravoProposal({
        proposalId: 0,
        proposer: address(0),
        eta: 0,
        targets: targets,
        values: values,
        signatures: signatures,
        calldatas: calldatas,
        startBlock: 0,
        endBlock: 0,
        forVotes: 0,
        againstVotes: 0,
        abstainVotes: 0,
        canceled: false,
        executed: false
      });
      setBravoProposal(res[i], governor, proposalIds[i]);
    }
    return res;
  }

  struct CompBalanceMetadata {
    uint256 balance;
    uint256 votes;
    address delegate;
  }

  function getCompBalanceMetadata(ICToken comp, address account) external view returns (CompBalanceMetadata memory) {
    return
      CompBalanceMetadata({
        balance: comp.balanceOf(account),
        votes: uint256(comp.getCurrentVotes(account)),
        delegate: comp.delegates(account)
      });
  }

  struct CompBalanceMetadataExt {
    uint256 balance;
    uint256 votes;
    address delegate;
    uint256 allocated;
  }

  function getCompBalanceMetadataExt(
    ICToken comp,
    IComptroller comptroller,
    address account
  ) external returns (CompBalanceMetadataExt memory) {
    uint256 balance = comp.balanceOf(account);
    comptroller.claimSumer(account);
    uint256 newBalance = comp.balanceOf(account);
    uint256 accrued = comptroller.compAccrued(account);
    uint256 total = add(accrued, newBalance, 'sum comp total');
    uint256 allocated = sub(total, balance, 'sub allocated');

    return
      CompBalanceMetadataExt({
        balance: balance,
        votes: uint256(comp.getCurrentVotes(account)),
        delegate: comp.delegates(account),
        allocated: allocated
      });
  }

  struct CompVotes {
    uint256 blockNumber;
    uint256 votes;
  }

  function getCompVotes(
    ICToken comp,
    address account,
    uint32[] calldata blockNumbers
  ) external view returns (CompVotes[] memory) {
    CompVotes[] memory res = new CompVotes[](blockNumbers.length);
    for (uint256 i = 0; i < blockNumbers.length; i++) {
      res[i] = CompVotes({
        blockNumber: uint256(blockNumbers[i]),
        votes: uint256(comp.getPriorVotes(account, blockNumbers[i]))
      });
    }
    return res;
  }

  function compareStrings(string memory a, string memory b) internal pure returns (bool) {
    return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
  }

  function add(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c >= a, errorMessage);
    return c;
  }

  function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
    require(b <= a, errorMessage);
    uint256 c = a - b;
    return c;
  }

  function getCollateralRate(
    IComptroller comptroller,
    address collateralToken,
    address liabilityToken
  ) public view returns (uint256) {
    (bool isListedCollateral, uint8 collateralGroupId, ) = comptroller.markets(collateralToken);
    if (!isListedCollateral) {
      revert MarketNotListed();
    }
    (bool isListedLiability, uint8 liabilityGroupId, ) = comptroller.markets(liabilityToken);
    if (!isListedLiability) {
      revert MarketNotListed();
    }

    bool collateralIsCToken = ICToken(collateralToken).isCToken();
    bool liabilityIsCToken = ICToken(liabilityToken).isCToken();

    if (collateralIsCToken) {
      // collateral is cToken
      if (collateralGroupId == liabilityGroupId) {
        // collaterl/liability is in the same group
        if (liabilityIsCToken) {
          return uint256(comptroller.assetGroup(collateralGroupId).intraCRatePercent) * percentScale;
        } else {
          return uint256(comptroller.assetGroup(collateralGroupId).intraMintRatePercent) * percentScale;
        }
      } else {
        // collateral/liability is not in the same group
        return uint256(comptroller.assetGroup(collateralGroupId).interCRatePercent) * percentScale;
      }
    } else {
      // collateral is suToken
      if (collateralGroupId == liabilityGroupId) {
        // collaterl/liability is in the same group
        return uint256(comptroller.assetGroup(collateralGroupId).intraSuRatePercent) * percentScale;
      } else {
        // collateral/liability is not in the same group
        return uint256(comptroller.assetGroup(collateralGroupId).interSuRatePercent) * percentScale;
      }
    }
  }

  function calcBorrowAmountForProtectedMint(
    address account,
    address cTokenCollateral,
    address suToken,
    uint256 suBorrowAmount
  ) public view returns (uint256, uint256) {
    IComptroller comptroller = IComptroller(ICToken(cTokenCollateral).comptroller());
    require(address(comptroller) == ICToken(suToken).comptroller(), 'not the same comptroller');

    (uint256 liquidity, ) = comptroller.getHypotheticalAccountLiquidity(account, cTokenCollateral, 0, 0);
    uint256 maxCBorrowAmount = (liquidity * expScale) / comptroller.getUnderlyingPriceNormalized(cTokenCollateral);

    address[] memory assets = comptroller.getAssetsIn(account);
    (, uint8 suGroupId, ) = comptroller.markets(suToken);

    uint256 shortfallMantissa = comptroller.getUnderlyingPriceNormalized(suToken) * suBorrowAmount;
    uint256 liquidityMantissa = 0;

    for (uint256 i = 0; i < assets.length; ++i) {
      address asset = assets[i];
      (, uint8 assetGroupId, ) = comptroller.markets(asset);

      // only consider asset in the same group
      if (assetGroupId != suGroupId) {
        continue;
      }

      (uint256 depositBalance, uint256 borrowBalance, uint256 exchangeRateMantissa, ) = ICToken(asset)
        .getAccountSnapshot(account);

      // get token price
      uint256 tokenPriceMantissa = comptroller.getUnderlyingPriceNormalized(asset);

      uint256 tokenCollateralRateMantissa = getCollateralRate(comptroller, asset, suToken);

      if (asset == suToken) {
        shortfallMantissa = shortfallMantissa + tokenPriceMantissa * borrowBalance;
      } else {
        liquidityMantissa =
          liquidityMantissa +
          (tokenPriceMantissa * depositBalance * exchangeRateMantissa * tokenCollateralRateMantissa) /
          expScale /
          expScale;
      }
    }
    if (shortfallMantissa <= liquidityMantissa) {
      return (0, maxCBorrowAmount);
    }

    return (
      ((shortfallMantissa - liquidityMantissa) * expScale) /
        comptroller.getUnderlyingPriceNormalized(cTokenCollateral) /
        getCollateralRate(IComptroller(comptroller), cTokenCollateral, suToken),
      maxCBorrowAmount
    );
  }

  // version is enabled after V3
  function version() external pure returns (Version) {
    return Version.V4;
  }
}
