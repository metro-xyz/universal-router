// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;
pragma abicoder v2;

import {V3Path} from './V3Path.sol';
import {BytesLib} from './BytesLib.sol';
import {SafeCast} from '@uniswap/v3-core/contracts/libraries/SafeCast.sol';
import {IUniswapV3Pool} from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import {IUniswapV3SwapCallback} from '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';
import {Constants} from '../../../libraries/Constants.sol';
import {RouterImmutables, AggregatorV3Interface} from '../../../base/RouterImmutables.sol';
import {Permit2Payments} from '../../Permit2Payments.sol';
import {Constants} from '../../../libraries/Constants.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';

interface IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

/// @title Router for Uniswap v3 Trades
abstract contract V3SwapRouter is RouterImmutables, Permit2Payments, IUniswapV3SwapCallback {
    using V3Path for bytes;
    using BytesLib for bytes;
    using SafeCast for uint256;

    error V3InvalidSwap();
    error V3TooLittleReceived();
    error V3TooMuchRequested();
    error V3InvalidAmountOut();
    error V3InvalidCaller();

    /// @dev Used as the placeholder value for maxAmountIn, because the computed amount in for an exact output swap
    /// can never actually be this value
    uint256 private constant DEFAULT_MAX_AMOUNT_IN = type(uint256).max;

    /// @dev Transient storage variable used for checking slippage
    uint256 private maxAmountInCached = DEFAULT_MAX_AMOUNT_IN;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;

    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (amount0Delta <= 0 && amount1Delta <= 0) revert V3InvalidSwap(); // swaps entirely within 0-liquidity regions are not supported
        (, address payer) = abi.decode(data, (bytes, address));
        bytes calldata path = data.toBytes(0);

        // because exact output swaps are executed in reverse order, in this case tokenOut is actually tokenIn
        (address tokenIn, uint24 fee, address tokenOut) = path.decodeFirstPool();

        if (computePoolAddress(tokenIn, tokenOut, fee) != msg.sender) revert V3InvalidCaller();

        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            // Pay the pool (msg.sender)
            payOrPermit2Transfer(tokenIn, payer, msg.sender, amountToPay);
        } else {
            // either initiate the next swap or pay
            if (path.hasMultiplePools()) {
                // this is an intermediate step so the payer is actually this contract
                path = path.skipToken();
                _swap(-amountToPay.toInt256(), msg.sender, path, payer, false);
            } else {
                if (amountToPay > maxAmountInCached) revert V3TooMuchRequested();
                // note that because exact output swaps are executed in reverse order, tokenOut is actually tokenIn
                payOrPermit2Transfer(tokenOut, payer, msg.sender, amountToPay);
            }
        }
    }

    /// @notice Performs a Uniswap v3 exact input swap
    /// @param recipient The recipient of the output tokens
    /// @param amountIn The amount of input tokens for the trade
    /// @param amountOutMinimum The minimum desired amount of output tokens
    /// @param path The path of the trade as a bytes string
    /// @param payer The address that will be paying the input
    function v3SwapExactInput(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        bytes calldata path,
        address payer
    ) internal {
        // use amountIn == Constants.CONTRACT_BALANCE as a flag to swap the entire balance of the contract
        if (amountIn == Constants.CONTRACT_BALANCE) {
            address tokenIn = path.decodeFirstToken();
            amountIn = ERC20(tokenIn).balanceOf(address(this));
        }

        uint256 amountSoldUsd;
        uint256 amountInHolder = amountIn;
        // Get the pool trade route from calldata path
        PoolInfo[] memory tradeRoutePools = getPoolsFromPath(path);

        (address firstTokenIn,,) = path.decodeFirstPool();
        address lastTokenOut;

        uint256 amountOut;

        uint256[] memory swapFees = new uint256[](tradeRoutePools.length);
        uint256[] memory swapFeesUSD = new uint256[](tradeRoutePools.length);
        uint256 poolIndex = 0;

        while (true) {
            bool hasMultiplePools = path.hasMultiplePools();

            // Decode the first pool in the path
            (address tokenIn,, address tokenOut) = path.decodeFirstPool();

            // the outputs of prior swaps become the inputs to subsequent ones
            (int256 amount0Delta, int256 amount1Delta, bool zeroForOne) = _swap(
                amountIn.toInt256(),
                hasMultiplePools ? address(this) : recipient, // for intermediate swaps, this contract custodies
                path.getFirstPool(), // only the first pool is needed
                payer, // for intermediate swaps, this contract custodies
                true
            );


            uint256 stepAmountOut = uint256(-(zeroForOne ? amount1Delta : amount0Delta));
            uint256 poolFee = tradeRoutePools[poolIndex].poolFee;
            uint256 feeInTokenIn = amountIn * poolFee / 1e6;
            uint256 amountOutBeforeFee = stepAmountOut * 1e6 / (1e6 - poolFee);
            uint256 feeInTokenOut = amountOutBeforeFee - stepAmountOut;

            swapFees[poolIndex] = feeInTokenIn;
            swapFeesUSD[poolIndex] = getUSDAmount(tokenIn, tokenOut, feeInTokenIn, feeInTokenOut);

            amountIn = stepAmountOut;

            // decide whether to continue or terminate
            if (hasMultiplePools) {
                payer = address(this);
                path = path.skipToken();
                poolIndex++;
            } else {
                amountOut = amountIn;
                lastTokenOut = tokenOut;
                break;
            }
        }

        if (amountOut < amountOutMinimum) revert V3TooLittleReceived();

        amountSoldUsd = getUSDAmount(firstTokenIn, lastTokenOut, amountInHolder, amountOut);

        // Populate structs
        ExchangeInfo memory exchangeInfo = getExchangeInfoV3();
        TokenInfo memory tokenSoldInfo = getTokenInfo(firstTokenIn);
        TokenInfo memory tokenBoughtInfo = getTokenInfo(lastTokenOut);

        // Initialize trader balance struct
        TraderBalanceDetails memory traderBalanceDetails = TraderBalanceDetails({
            tokenSoldBalanceBefore: getTraderTokenBalance(tx.origin, firstTokenIn),
            tokenSoldBalanceAfter: 0,
            tokenBoughtBalanceBefore: getTraderTokenBalance(tx.origin, lastTokenOut),
            tokenBoughtBalanceAfter: 0
        });

        // Check before subtracting in case we underflow
        if (traderBalanceDetails.tokenSoldBalanceBefore >= amountInHolder) {
            traderBalanceDetails.tokenSoldBalanceAfter = traderBalanceDetails.tokenSoldBalanceBefore - amountInHolder;
        } else {
            traderBalanceDetails.tokenSoldBalanceAfter = 0;
        }

        traderBalanceDetails.tokenBoughtBalanceAfter = traderBalanceDetails.tokenBoughtBalanceBefore + amountOut;

        // Emit shadow event
        emit Trade(
            tx.origin,
            amountSoldUsd,
            exchangeInfo,
            amountInHolder,
            tokenSoldInfo,
            amountOut,
            tokenBoughtInfo,
            tradeRoutePools,
            traderBalanceDetails,
            "AMM", // tradeType
            swapFees,
            swapFeesUSD
        );
    }

    /// @notice Performs a Uniswap v3 exact output swap
    /// @param recipient The recipient of the output tokens
    /// @param amountOut The amount of output tokens to receive for the trade
    /// @param amountInMaximum The maximum desired amount of input tokens
    /// @param path The path of the trade as a bytes string
    /// @param payer The address that will be paying the input
    function v3SwapExactOutput(
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        bytes calldata path,
        address payer
    ) internal {
        // Get the pool trade route from calldata path
        PoolInfo[] memory tradeRoutePools = getPoolsFromPath(path);
        // Decode the first pool in the path
        (address tokenIn, uint24 fee, address tokenOut) = path.decodeFirstPool();
        // Flip tokens for accounting because it's an exact output swap
        address flipTokenIn = tokenOut;
        address flipTokenOut = tokenIn;
        // Populate trader balance struct
        TraderBalanceDetails memory traderBalanceDetails = TraderBalanceDetails({
            tokenSoldBalanceBefore: getTraderTokenBalance(tx.origin, flipTokenIn),
            tokenSoldBalanceAfter: 0,
            tokenBoughtBalanceBefore: getTraderTokenBalance(tx.origin, flipTokenOut),
            tokenBoughtBalanceAfter: 0
        });

        uint256[] memory swapFees = new uint256[](tradeRoutePools.length);
        uint256[] memory swapFeesUSD = new uint256[](tradeRoutePools.length);

        maxAmountInCached = amountInMaximum;
        (int256 amount0Delta, int256 amount1Delta, bool zeroForOne) =
            _swap(-amountOut.toInt256(), recipient, path, payer, false);

        uint256 amountOutReceived = zeroForOne ? uint256(-amount1Delta) : uint256(-amount0Delta);

        if (amountOutReceived != amountOut) revert V3InvalidAmountOut();

        maxAmountInCached = DEFAULT_MAX_AMOUNT_IN;

        // Calculate the actual amount in and the USD values
        uint256 amountInActual = zeroForOne ? uint256(amount0Delta) : uint256(amount1Delta);
        uint256 amountSoldUsd = getUSDAmount(flipTokenIn, flipTokenOut, amountInActual, amountOutReceived);

        // Populate other info structs
        ExchangeInfo memory exchangeInfo = getExchangeInfoV3();

        TokenInfo memory tokenSoldInfo = getTokenInfo(flipTokenIn);
        TokenInfo memory tokenBoughtInfo = getTokenInfo(flipTokenOut);

        // Check before subtracting in case we underflow
        if (traderBalanceDetails.tokenSoldBalanceBefore >= amountInActual) {
            traderBalanceDetails.tokenSoldBalanceAfter = traderBalanceDetails.tokenSoldBalanceBefore - amountInActual;
        } else {
            traderBalanceDetails.tokenSoldBalanceAfter = 0;
        }

        traderBalanceDetails.tokenBoughtBalanceAfter = traderBalanceDetails.tokenBoughtBalanceBefore + amountOutReceived;

        // Emit shadow event
        emit Trade(
            tx.origin,
            amountSoldUsd,
            exchangeInfo,
            amountInActual,
            tokenSoldInfo,
            amountOutReceived,
            tokenBoughtInfo,
            tradeRoutePools,
            traderBalanceDetails,
            "AMM", // tradeType
            swapFees,
            swapFeesUSD
        );
    }

    /// @dev Performs a single swap for both exactIn and exactOut
    /// For exactIn, `amount` is `amountIn`. For exactOut, `amount` is `-amountOut`
    function _swap(int256 amount, address recipient, bytes calldata path, address payer, bool isExactIn)
        private
        returns (int256 amount0Delta, int256 amount1Delta, bool zeroForOne)
    {
        (address tokenIn, uint24 fee, address tokenOut) = path.decodeFirstPool();

        zeroForOne = isExactIn ? tokenIn < tokenOut : tokenOut < tokenIn;

        (amount0Delta, amount1Delta) = IUniswapV3Pool(computePoolAddress(tokenIn, tokenOut, fee)).swap(
            recipient,
            zeroForOne,
            amount,
            (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1),
            abi.encode(path, payer)
        );
    }

    function computePoolAddress(address tokenA, address tokenB, uint24 fee) private view returns (address pool) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex'ff',
                            UNISWAP_V3_FACTORY,
                            keccak256(abi.encode(tokenA, tokenB, fee)),
                            UNISWAP_V3_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    /// @dev helper function to populate ExchangeInfo struct
    function getExchangeInfoV3() private view returns (ExchangeInfo memory) {
        return ExchangeInfo({
            projectName: 'Uniswap',
            projectVersion: 'UniversalRouter',
            projectVersionDetails: 'V3SwapRouter',
            contractAddress: address(this)
        });
    }

    /// @dev helper function to populate PoolInfo struct
    function getPoolInfoV3(address poolAddress) internal view returns (PoolInfo memory) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        TokenInfo memory token0Info = getTokenInfo(pool.token0());
        TokenInfo memory token1Info = getTokenInfo(pool.token1());

        PoolInfo memory poolInfo;
        poolInfo.token0 = token0Info;
        poolInfo.token1 = token1Info;
        poolInfo.poolAddress = poolAddress;
        poolInfo.poolFee = pool.fee();
        poolInfo.tickSpacing = pool.tickSpacing();
        return poolInfo;
    }

    /// @dev helper function to get the pools from the path
    function getPoolsFromPath(bytes calldata path) internal view returns (PoolInfo[] memory) {
        uint256 numPools;
        bytes calldata tempPath = path;
        while (true) {
            numPools++;
            if (tempPath.hasMultiplePools()) {
                tempPath = tempPath.skipToken();
            } else {
                break;
            }
        }
        PoolInfo[] memory pools = new PoolInfo[](numPools);
        for (uint256 i = 0; i < numPools; i++) {
            (address tokenIn, uint24 fee, address tokenOut) = path.decodeFirstPool();
            path = path.skipToken();

            // Compute the pool address
            address poolAddress = computePoolAddress(tokenIn, tokenOut, fee);

            // Get pool info
            pools[i] = getPoolInfoV3(poolAddress);
        }
        return pools;
    }
}
