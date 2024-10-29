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
    Adapter
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
  uint8 constant DECIMALS = 18;
  uint256 constant EXP_SCALE = 10 ** 18;

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

  function setPythFeed(address asset, uint32 maxStalePeriod, bytes32 feedId) public onlyOwner {
    if (address(pythOracle) == address(0)) {
      revert EmptyPythOracle();
    }

    // sanity check
    if (maxStalePeriod == 0) {
      revert EmptyMaxStalePeriod();
    }

    pythFeeds[asset] = PythFeed({feedId: feedId, maxStalePeriod: maxStalePeriod});
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
    uint256 decimals = DECIMALS - uint32(expo * -1);
    require(decimals <= DECIMALS, 'decimal underflow');
    return uint64(price) * (10 ** decimals);
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
