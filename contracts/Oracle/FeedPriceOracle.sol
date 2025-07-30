// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import './PriceOracle.sol';
import '../Interfaces/IPendlePtOracle.sol';
import '../Interfaces/IPMarket.sol';
import '../Interfaces/IPPrincipalToken.sol';
import '../Interfaces/IPYieldToken.sol';
import '../Interfaces/IStandardizedYield.sol';
import '@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol';
import '@pythnetwork/pyth-sdk-solidity/IPyth.sol';
import '@openzeppelin/contracts/access/Ownable2Step.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '../Interfaces/ICTokenExternal.sol';
import '../Interfaces/ILayerBank.sol';
import '../Interfaces/IVault.sol';
import '../Interfaces/IPool.sol';
// import '../Interfaces/UniswapV2.sol';
// import '../Interfaces/Kodiak.sol';

import './VaultReentrancyLib.sol';
import './FixedPointMathLib.sol';

error ZeroAddressNotAllowed();
error ZeroValueNotAllowed();

error EmptyPythOracle(); // thrown when pythOracle is empty
error EmptyPendlePtOracle(); // thrown when pendlePtOralce is empty

error UnknownSource(); // thrown when source is unknown during getPrice
error UnsupportedSource(); // thrown when source is not supported during getPrice

// sanity checks
error InvalidFeedDecimals();
error EmptyFeedAddress();
error EmptyAdapterAddress();
error EmptyMaxStalePeriod();

error InvalidPrice(); // thrown when price is 0
error InvalidDecimals();

/// @notice Checks if the provided address is nonzero, reverts otherwise
/// @param address_ Address to check
/// @custom:error ZeroAddressNotAllowed is thrown if the provided address is a zero address
function ensureNonzeroAddress(address address_) pure {
  if (address_ == address(0)) {
    revert ZeroAddressNotAllowed();
  }
}

/// @notice Checks if the provided value is nonzero, reverts otherwise
/// @param value_ Value to check
/// @custom:error ZeroValueNotAllowed is thrown if the provided value is 0
function ensureNonzeroValue(uint256 value_) pure {
  if (value_ == 0) {
    revert ZeroValueNotAllowed();
  }
}

contract FeedPriceOracle is PriceOracle, Ownable2Step {
  using SafeMath for uint256;

  enum Source {
    Unknown,
    Chainlink,
    RedStone,
    Pyth,
    Pendle,
    FixedPrice,
    Adapter,
    Layerbank,
    Balancer // compatible with balancer v2 and balancer v3
    // UniswapV2,
    // KodiakIsland
  }

  struct ChainlinkFeed {
    address feedAddr; // feed address
    address denominator; // price will be denominated by this address, address(0) means USD
    uint8 feedDecimals; // feed decimals (only used in witnet)
    uint32 maxStalePeriod; //  Price expiration period of this asset
  }

  struct PythFeed {
    bytes32 feedId;
    uint32 maxStalePeriod;
    address denominator;
  }

  struct PendleFeed {
    address market;
    address yieldToken;
    uint32 twapDuration;
  }

  struct AdapterFeed {
    address adapterAddr;
    address denominator;
  }

  struct LayerBankFeed {
    address feedAddr;
    address feedAssetAddr;
  }

  struct BalancerFeed {
    bool isStable;
  }

  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;

  event NewFeed(address indexed asset, Source source, uint8 feedDecimals, uint32 maxStalePeriod, bytes32 metadata);
  event NewPythOracle(address oldValue, address newValue);
  event NewPendlePtOracle(address oldValue, address newValue);

  address public immutable nativeMarket;
  address public immutable nativeAsset;

  IPyth public pythOracle;
  IPendlePtOracle public pendlePtOracle;
  mapping(address => ChainlinkFeed) public chainlinkFeeds; // asset -> chainlink feeds
  mapping(address => ChainlinkFeed) public redstoneFeeds; // asset -> redstone feeds
  mapping(address => PythFeed) public pythFeeds; // asset -> pyth feeds
  mapping(address => PendleFeed) public pendleFeeds; // asset -> pendle feeds
  mapping(address => uint256) public fixedPrices; // asset -> price
  mapping(address => AdapterFeed) public adapterFeeds; // asset -> adapter feeds

  mapping(address => Source) public mainSource; // asset -> source
  uint8 constant ORACLE_DECIMALS = 18;
  uint256 constant EXP_SCALE = 10 ** 18;

  mapping(address => LayerBankFeed) public layerbankFeeds; // asset -> layerbank feeds
  mapping(address => BalancerFeed) public balancerFeeds; // asset -> balancer feeds

  constructor(
    address admin,
    address nativeMarket_,
    address nativeAsset_,
    IPyth pythOracle_,
    IPendlePtOracle pendlePtOracle_
  ) {
    pythOracle = pythOracle_;
    nativeMarket = nativeMarket_;
    nativeAsset = nativeAsset_;
    if (address(pythOracle_) != address(0)) {
      emit NewPythOracle(address(0), address(pythOracle));
    }

    pendlePtOracle = pendlePtOracle_;
    if (address(pendlePtOracle_) != address(0)) {
      emit NewPendlePtOracle(address(0), address(pendlePtOracle));
    }

    _transferOwnership(admin);
  }

  ///////////////////////////////////////////////////
  // Chainlink
  ///////////////////////////////////////////////////
  function setChainlinkFeed(
    address asset,
    address feedAddr,
    uint32 maxStalePeriod,
    address denominator
  ) public onlyOwner {
    uint8 decimals = AggregatorV3Interface(feedAddr).decimals();
    if (feedAddr == address(0)) {
      revert EmptyFeedAddress();
    }
    if (decimals == 0) {
      revert InvalidFeedDecimals();
    }
    if (maxStalePeriod == 0) {
      revert EmptyMaxStalePeriod();
    }

    chainlinkFeeds[asset] = ChainlinkFeed({
      feedAddr: feedAddr,
      feedDecimals: decimals,
      maxStalePeriod: maxStalePeriod,
      denominator: denominator
    });
    if (mainSource[asset] == Source.Unknown) {
      mainSource[asset] = Source.Chainlink;
    }
  }

  function _getChainlinkPrice(ChainlinkFeed memory feedData) internal view returns (uint256) {
    AggregatorV3Interface feed = AggregatorV3Interface(feedData.feedAddr);

    // note: maxStalePeriod cannot be 0
    uint256 maxStalePeriod = feedData.maxStalePeriod;

    // Chainlink USD-denominated feeds store answers at 8 decimals, mostly
    uint256 decimalDelta = 18 - feedData.feedDecimals;

    (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
    if (answer <= 0) revert('chainlink price must be positive');
    if (block.timestamp < updatedAt) revert('updatedAt exceeds block time');

    uint256 deltaTime;
    unchecked {
      deltaTime = block.timestamp - updatedAt;
    }

    if (deltaTime > maxStalePeriod) revert('chainlink price expired');

    uint256 price = uint256(answer) * (10 ** decimalDelta);
    if (feedData.denominator != address(0)) {
      price = (price * getPrice(feedData.denominator)) / EXP_SCALE;
    }
    return price;
  }

  function removeChainlinkFeed(address asset) public onlyOwner {
    delete chainlinkFeeds[asset];
    if (mainSource[asset] == Source.Chainlink) {
      mainSource[asset] = Source.Unknown;
    }
  }

  ///////////////////////////////////////////////////
  // RedStone
  ///////////////////////////////////////////////////
  function setRedStoneFeed(
    address asset,
    address feedAddr,
    uint32 maxStalePeriod,
    address denominator
  ) public onlyOwner {
    uint8 decimals = AggregatorV3Interface(feedAddr).decimals();
    if (feedAddr == address(0)) {
      revert EmptyFeedAddress();
    }
    if (decimals == 0) {
      revert InvalidFeedDecimals();
    }
    if (maxStalePeriod == 0) {
      revert EmptyMaxStalePeriod();
    }

    redstoneFeeds[asset] = ChainlinkFeed({
      feedAddr: feedAddr,
      feedDecimals: decimals,
      maxStalePeriod: maxStalePeriod,
      denominator: denominator
    });
    if (mainSource[asset] == Source.Unknown) {
      mainSource[asset] = Source.RedStone;
    }
  }

  function removeRedstoneFeed(address asset) public onlyOwner {
    delete redstoneFeeds[asset];
    if (mainSource[asset] == Source.RedStone) {
      mainSource[asset] = Source.Unknown;
    }
  }

  ///////////////////////////////////////////////////
  // Pyth
  ///////////////////////////////////////////////////
  function setPythOracle(IPyth pythOracle_) public onlyOwner {
    address oldValue = address(pythOracle);
    ensureNonzeroAddress(address(pythOracle_));
    pythOracle = pythOracle_;
    emit NewPythOracle(oldValue, address(pythOracle));
  }

  function setPythFeed(address asset, uint32 maxStalePeriod, bytes32 feedId, address denominator) public onlyOwner {
    if (address(pythOracle) == address(0)) {
      revert EmptyPythOracle();
    }

    // sanity check
    if (maxStalePeriod == 0) {
      revert EmptyMaxStalePeriod();
    }

    pythFeeds[asset] = PythFeed({feedId: feedId, maxStalePeriod: maxStalePeriod, denominator: denominator});
    if (mainSource[asset] == Source.Unknown) {
      mainSource[asset] = Source.Pyth;
    }
  }

  function _getPythPrice(PythFeed memory feedData) internal view returns (uint256) {
    if (address(pythOracle) == address(0)) {
      revert EmptyPythOracle();
    }

    (bool success, bytes memory message) = address(pythOracle).staticcall(
      abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector, feedData.feedId, feedData.maxStalePeriod)
    );
    require(success, 'pyth error');
    (int64 price, , int32 expo, ) = (abi.decode(message, (int64, uint64, int32, uint256)));
    uint256 decimals = ORACLE_DECIMALS - uint32(expo * -1);
    require(decimals <= ORACLE_DECIMALS, 'decimal underflow');
    uint256 actualPrice = uint64(price) * (10 ** decimals);
    if (feedData.denominator != address(0)) {
      actualPrice = (actualPrice * getPrice(feedData.denominator)) / EXP_SCALE;
    }
    return actualPrice;
  }

  function removePythFeed(address asset) public onlyOwner {
    delete pythFeeds[asset];
    if (mainSource[asset] == Source.Pyth) {
      mainSource[asset] = Source.Unknown;
    }
  }

  ///////////////////////////////////////////////////
  // Pendle
  ///////////////////////////////////////////////////
  function setPendlePtOracle(IPendlePtOracle pendlePtOracle_) public onlyOwner {
    address oldValue = address(pendlePtOracle);
    ensureNonzeroAddress(address(pendlePtOracle_));
    pendlePtOracle = pendlePtOracle_;
    emit NewPendlePtOracle(oldValue, address(pendlePtOracle));
  }

  function setPendleFeed(address asset, address market, uint32 twapDuration, address yieldToken) public onlyOwner {
    if (address(pendlePtOracle) == address(0)) {
      revert EmptyPendlePtOracle();
    }

    // sanity check
    ensureNonzeroAddress(market);
    ensureNonzeroAddress(yieldToken);
    ensureNonzeroValue(uint256(twapDuration));
    (IStandardizedYield sy, IPPrincipalToken pt, ) = IPMarket(market).readTokens();
    if (asset != address(pt)) revert('pt mismatch');
    if (pt.SY() != address(sy)) revert('sy mismatch');
    if (sy.yieldToken() != yieldToken) revert('yieldToken mismatch');

    pendleFeeds[asset] = PendleFeed({market: market, twapDuration: twapDuration, yieldToken: yieldToken});
    if (mainSource[asset] == Source.Unknown) {
      mainSource[asset] = Source.Pendle;
    }
  }

  function _getPendlePrice(PendleFeed memory feedData) internal view returns (uint256) {
    if (address(pendlePtOracle) == address(0)) {
      revert EmptyPendlePtOracle();
    }
    uint256 rate = pendlePtOracle.getPtToSyRate(feedData.market, feedData.twapDuration);
    return (getPrice(feedData.yieldToken) * rate) / EXP_SCALE;
  }

  function removePendleFeed(address asset) public onlyOwner {
    delete pendleFeeds[asset];
    if (mainSource[asset] == Source.Pendle) {
      mainSource[asset] = Source.Unknown;
    }
  }

  ///////////////////////////////////////////////////
  // FixedPrice
  ///////////////////////////////////////////////////
  function setFixedPrice(address asset, uint256 price) public onlyOwner {
    ensureNonzeroAddress(asset);
    ensureNonzeroValue(price);
    fixedPrices[asset] = price;
    if (mainSource[asset] == Source.Unknown) {
      mainSource[asset] = Source.FixedPrice;
    }
  }

  function getFixedPrice(address asset) public view returns (uint256) {
    return fixedPrices[asset];
  }

  function removeFixedPrice(address asset) public onlyOwner {
    delete fixedPrices[asset];
    if (mainSource[asset] == Source.FixedPrice) {
      mainSource[asset] = Source.Unknown;
    }
  }

  ///////////////////////////////////////////////////
  // Adapter
  ///////////////////////////////////////////////////
  function setAdapterFeed(address asset, address adapterAddr, address denominator) public onlyOwner {
    if (adapterAddr == address(0)) {
      revert EmptyAdapterAddress();
    }
    adapterFeeds[asset] = AdapterFeed({adapterAddr: adapterAddr, denominator: denominator});
    if (mainSource[asset] == Source.Unknown) {
      mainSource[asset] = Source.Adapter;
    }
  }

  function _getAdapterPrice(AdapterFeed memory feedData) internal view returns (uint256) {
    uint256 price = PriceAdapter(feedData.adapterAddr).exchangeRate();
    if (feedData.denominator != address(0)) {
      price = (price * getPrice(feedData.denominator)) / EXP_SCALE;
    }
    return price;
  }

  function removeAdapterFeed(address asset) public onlyOwner {
    delete fixedPrices[asset];
    if (mainSource[asset] == Source.Adapter) {
      mainSource[asset] = Source.Unknown;
    }
  }

  ///////////////////////////////////////////////////
  // Layerbank
  ///////////////////////////////////////////////////
  function setLayerbankFeed(address asset, address feedAddr, address feedAssetAddr) public onlyOwner {
    if (feedAddr == address(0)) {
      revert EmptyFeedAddress();
    }

    layerbankFeeds[asset] = LayerBankFeed({feedAddr: feedAddr, feedAssetAddr: feedAssetAddr});
    if (mainSource[asset] == Source.Unknown) {
      mainSource[asset] = Source.Layerbank;
    }
  }

  function _getLayerbankPrice(LayerBankFeed memory feedData) internal view returns (uint256) {
    ILayerBank feed = ILayerBank(feedData.feedAddr);

    uint256 price = feed.priceOf(feedData.feedAssetAddr);
    return price;
  }

  function removeLayerbankFeed(address asset) public onlyOwner {
    delete layerbankFeeds[asset];
    if (mainSource[asset] == Source.Layerbank) {
      mainSource[asset] = Source.Unknown;
    }
  }

  ///////////////////////////////////////////////////
  // Layerbank
  ///////////////////////////////////////////////////
  function setBalancerFeed(address asset, bool isStable) public onlyOwner {
    balancerFeeds[asset] = BalancerFeed({isStable: isStable});
    if (mainSource[asset] == Source.Unknown) {
      mainSource[asset] = Source.Balancer;
    }
  }

  function _getBalancerPrice(address lpAddress, bool isStable) internal view returns (uint256) {
    if (isStable) {
      return _getBalancerStablePrice(lpAddress);
    } else {
      return _getBalancerVariablePrice(lpAddress);
    }
  }

  function _getBalancerVariablePrice(address lpAddress) internal view returns (uint256) {
    VaultReentrancyLib.ensureNotInVaultContext(IVault(IPool(lpAddress).getVault()));
    IPool pool = IPool(lpAddress);
    address vaultAddr = pool.getVault();
    bytes32 poolId = pool.getPoolId();

    uint8 lpDecimals = pool.decimals();
    uint256 actualSupply = pool.getActualSupply() * (10 ** (ORACLE_DECIMALS - lpDecimals)); // make it decimals 18
    (address[] memory tokens, uint256[] memory balances, ) = IVault(vaultAddr).getPoolTokens(poolId);

    // 18 decimals
    uint256 price0 = getPrice(tokens[0]);
    uint256 price1 = getPrice(tokens[1]);

    uint256[] memory weights = pool.getNormalizedWeights();

    int256 product0 = int256(price0.divWad(weights[0])).powWad(int256(weights[0]));
    int256 product1 = int256(price1.divWad(weights[1])).powWad(int256(weights[1]));

    uint256 product = uint256(product0.sMulWad(product1));

    uint256 totalSupply;

    try pool.getActualSupply() returns (uint256 _totalSupply) {
      totalSupply = _totalSupply;
    } catch {
      totalSupply = pool.totalSupply();
    }

    uint256 invariant = pool.getInvariant();

    return invariant.mulWad(uint256(product)).divWad(totalSupply);
  }

  function _getBalancerStablePrice(address lpAddress) internal view returns (uint256) {
    VaultReentrancyLib.ensureNotInVaultContext(IVault(IPool(lpAddress).getVault()));
    IPool pool = IPool(lpAddress);
    address vaultAddr = pool.getVault();
    bytes32 poolId = pool.getPoolId();

    uint8 lpDecimals = pool.decimals();
    uint256 actualSupply = pool.getActualSupply() * (10 ** (ORACLE_DECIMALS - lpDecimals)); // make it decimals 18
    (address[] memory tokens, uint256[] memory balances, ) = IVault(vaultAddr).getPoolTokens(poolId);

    uint256 min = type(uint256).max;

    uint256 totalValue = 0;
    for (uint256 i = 0; i < tokens.length; i++) {
      address token = tokens[i];
      if (token == lpAddress) {
        continue;
      }
      uint256 price = getPrice(token);
      if (price <= 0) {
        revert InvalidPrice();
      }
      uint8 decimals = IERC20Metadata(token).decimals();
      totalValue += price * balances[i] * (10 ** (ORACLE_DECIMALS - decimals)); // price decimals 18, token decimals 18

      try pool.getTokenRate(token) returns (uint256 rate) {
        price = price.divWad(rate);
      } catch {}

      if (price < min) {
        min = price;
      }
    }

    uint256 poolRate = pool.getRate();
    return min.mulWad(poolRate);
  }

  function removeBalancerFeed(address asset) public onlyOwner {
    delete balancerFeeds[asset];
    if (mainSource[asset] == Source.Balancer) {
      mainSource[asset] = Source.Unknown;
    }
  }

  ///////////////////////////////////////////////////
  // Set Main Source
  ///////////////////////////////////////////////////
  function setMainSource(address asset, Source source) public onlyOwner {
    mainSource[asset] = source;
  }

  ///////////////////////////////////////////////////
  // GET PRICE
  ///////////////////////////////////////////////////
  function getPrice(address asset) public view override returns (uint256) {
    Source source = mainSource[asset];
    if (source == Source.Unknown) {
      revert UnknownSource();
    }

    uint256 price;

    if (source == Source.Chainlink) {
      // Chainlink
      ChainlinkFeed memory feedData = chainlinkFeeds[asset];
      price = _getChainlinkPrice(feedData);
    } else if (source == Source.RedStone) {
      // RedStone
      ChainlinkFeed memory feedData = redstoneFeeds[asset];
      price = _getChainlinkPrice(feedData);
    } else if (source == Source.Pyth) {
      // Pyth
      PythFeed memory feedData = pythFeeds[asset];
      price = _getPythPrice(feedData);
    } else if (source == Source.Pendle) {
      // Pendle
      PendleFeed memory feedData = pendleFeeds[asset];
      price = _getPendlePrice(feedData);
    } else if (source == Source.FixedPrice) {
      // Fixed Price
      price = fixedPrices[asset];
    } else if (source == Source.Adapter) {
      // Adapter
      AdapterFeed memory feedData = adapterFeeds[asset];
      price = _getAdapterPrice(feedData);
    } else if (source == Source.Layerbank) {
      // Layerbank
      LayerBankFeed memory feedData = layerbankFeeds[asset];
      price = _getLayerbankPrice(feedData);
    } else {
      revert UnsupportedSource();
    }

    if (price == uint256(0)) {
      revert InvalidPrice();
    }
    return price;
  }

  function getUnderlyingPrice(address ctoken) public view override returns (uint256) {
    address asset;
    if (ctoken == nativeMarket) {
      asset = nativeAsset;
    } else {
      asset = ICToken(ctoken).underlying();
    }

    return getPrice(asset);
  }

  function getUnderlyingPrices(address[] memory cTokens) public view returns (uint256[] memory) {
    uint256 length = cTokens.length;
    uint256[] memory results = new uint256[](length);
    for (uint256 i; i < length; ++i) {
      results[i] = getUnderlyingPrice(cTokens[i]);
    }
    return results;
  }
}
