// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {IAllowanceTransfer} from 'permit2/src/interfaces/IAllowanceTransfer.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';
import {IWETH9} from '../interfaces/external/IWETH9.sol';

struct RouterParameters {
    address permit2;
    address weth9;
    address seaportV1_5;
    address seaportV1_4;
    address openseaConduit;
    address nftxZap;
    address x2y2;
    address foundation;
    address sudoswap;
    address elementMarket;
    address nft20Zap;
    address cryptopunks;
    address looksRareV2;
    address routerRewardsDistributor;
    address looksRareRewardsDistributor;
    address looksRareToken;
    address v2Factory;
    address v3Factory;
    bytes32 pairInitCodeHash;
    bytes32 poolInitCodeHash;
}

interface IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

/// @title Router Immutable Storage contract
/// @notice Used along with the `RouterParameters` struct for ease of cross-chain deployment
contract RouterImmutables {
    event Trade(
        address trader,
        uint256 amountUSDE6,
        ExchangeInfo exchangeInfo,
        uint256 tokenSoldAmount,
        TokenInfo tokenSoldInfo,
        uint256 tokenBoughtAmount,
        TokenInfo tokenBoughtInfo,
        PoolInfo[] tradeRoutePools,
        TraderBalanceDetails traderBalanceDetails,
        string tradeType,
        uint256[] swapFees
    );

    // struct for exchange information
    struct ExchangeInfo {
        string projectName;
        string projectVersion;
        string projectVersionDetails;
        address contractAddress;
    }

    // struct for general token information
    struct TokenInfo {
        // token symbol, e.g. "WETH"
        string tokenSymbol;
        // token name, e.g. "Wrapped Ether"
        string tokenName;
        // token address
        address tokenAddress;
        // token decimals
        uint8 tokenDecimals;
    }

    // struct for general token information
    struct PoolInfo {
        // token0 of the pool
        TokenInfo token0;
        // token1 of the pool
        TokenInfo token1;
        // address of the pool
        address poolAddress;
        // fee for the pool, expressed in hundredths of a bip, i.e. 1e-6
        uint24 poolFee;
        // the tick spacing for the pool
        int24 tickSpacing;
    }

    struct TraderBalanceDetails {
        uint256 tokenSoldBalanceBefore;
        uint256 tokenSoldBalanceAfter;
        uint256 tokenBoughtBalanceBefore;
        uint256 tokenBoughtBalanceAfter;
    }

    /// @dev WETH9 address
    IWETH9 internal immutable WETH9;

    /// @dev Permit2 address
    IAllowanceTransfer internal immutable PERMIT2;

    /// @dev Seaport 1.5 address
    address internal immutable SEAPORT_V1_5;

    /// @dev Seaport 1.4 address
    address internal immutable SEAPORT_V1_4;

    /// @dev The address of OpenSea's conduit used in both Seaport 1.4 and Seaport 1.5
    address internal immutable OPENSEA_CONDUIT;

    /// @dev The address of NFTX zap contract for interfacing with vaults
    address internal immutable NFTX_ZAP;

    /// @dev The address of X2Y2
    address internal immutable X2Y2;

    // @dev The address of Foundation
    address internal immutable FOUNDATION;

    // @dev The address of Sudoswap's router
    address internal immutable SUDOSWAP;

    // @dev The address of Element Market
    address internal immutable ELEMENT_MARKET;

    // @dev the address of NFT20's zap contract
    address internal immutable NFT20_ZAP;

    // @dev the address of Larva Lab's cryptopunks marketplace
    address internal immutable CRYPTOPUNKS;

    /// @dev The address of LooksRareV2
    address internal immutable LOOKS_RARE_V2;

    /// @dev The address of LooksRare token
    ERC20 internal immutable LOOKS_RARE_TOKEN;

    /// @dev The address of LooksRare rewards distributor
    address internal immutable LOOKS_RARE_REWARDS_DISTRIBUTOR;

    /// @dev The address of router rewards distributor
    address internal immutable ROUTER_REWARDS_DISTRIBUTOR;

    /// @dev The address of UniswapV2Factory
    address internal immutable UNISWAP_V2_FACTORY;

    /// @dev The UniswapV2Pair initcodehash
    bytes32 internal immutable UNISWAP_V2_PAIR_INIT_CODE_HASH;

    /// @dev The address of UniswapV3Factory
    address internal immutable UNISWAP_V3_FACTORY;

    /// @dev The UniswapV3Pool initcodehash
    bytes32 internal immutable UNISWAP_V3_POOL_INIT_CODE_HASH;

    enum Spenders {
        OSConduit,
        Sudoswap
    }

    constructor(RouterParameters memory params) {
        PERMIT2 = IAllowanceTransfer(params.permit2);
        WETH9 = IWETH9(params.weth9);
        SEAPORT_V1_5 = params.seaportV1_5;
        SEAPORT_V1_4 = params.seaportV1_4;
        OPENSEA_CONDUIT = params.openseaConduit;
        NFTX_ZAP = params.nftxZap;
        X2Y2 = params.x2y2;
        FOUNDATION = params.foundation;
        SUDOSWAP = params.sudoswap;
        ELEMENT_MARKET = params.elementMarket;
        NFT20_ZAP = params.nft20Zap;
        CRYPTOPUNKS = params.cryptopunks;
        LOOKS_RARE_V2 = params.looksRareV2;
        LOOKS_RARE_TOKEN = ERC20(params.looksRareToken);
        LOOKS_RARE_REWARDS_DISTRIBUTOR = params.looksRareRewardsDistributor;
        ROUTER_REWARDS_DISTRIBUTOR = params.routerRewardsDistributor;
        UNISWAP_V2_FACTORY = params.v2Factory;
        UNISWAP_V2_PAIR_INIT_CODE_HASH = params.pairInitCodeHash;
        UNISWAP_V3_FACTORY = params.v3Factory;
        UNISWAP_V3_POOL_INIT_CODE_HASH = params.poolInitCodeHash;
    }

    // Get the current price of ETH from Chainlink's ETH/USD oracle (8 decimals)
    function getPriceETH() internal view returns (int256) {
        AggregatorV3Interface dataFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        (, int256 answer,,,) = dataFeed.latestRoundData();
        return answer;
    }

    // Get the USD amount of a trade. Return amountIn in USD if tokenIn is WETH or stablecoin. Else, return amountOut in USD if tokenOut is WETH or stablecoin. Else, return 0.
    function getUSDAmount(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        returns (uint256)
    {
        if (
            tokenIn == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
                || tokenIn == 0xdAC17F958D2ee523a2206206994597C13D831ec7
                || tokenIn == 0x6B175474E89094C44Da98b954EedeAC495271d0F
        ) {
            return amountIn;
        } else if (tokenIn == address(WETH9)) {
            return amountIn * uint256(getPriceETH()) * 1e6 / 1e18 / 1e8;
        } else if (
            tokenOut == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
                || tokenOut == 0xdAC17F958D2ee523a2206206994597C13D831ec7
                || tokenOut == 0x6B175474E89094C44Da98b954EedeAC495271d0F
        ) {
            return amountOut;
        } else if (tokenOut == address(WETH9)) {
            return amountOut * uint256(getPriceETH()) * 1e6 / 1e18 / 1e8;
        } else {
            return 0;
        }
    }

    /// @dev helper function to populate TokenInfo struct
    function getTokenInfo(address tokenAddress) internal view returns (TokenInfo memory) {
        TokenInfo memory tokenInfo;
        tokenInfo.tokenAddress = tokenAddress;
        tokenInfo.tokenSymbol = IERC20(tokenAddress).symbol();
        tokenInfo.tokenName = IERC20(tokenAddress).name();
        tokenInfo.tokenDecimals = IERC20(tokenAddress).decimals();
        return tokenInfo;
    }

    /// @dev helper function to get a trader's token balance. if the token is WETH, then sum up WETH + native ETH balances
    function getTraderTokenBalance(address traderAddress, address tokenAddress) internal returns (uint256 balance) {
        if (tokenAddress == 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) {
            balance = IERC20(tokenAddress).balanceOf(traderAddress) + traderAddress.balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(traderAddress);
        }
        return balance;
    }
}

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
