// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {IUniswapV2Pair} from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import {UniswapV2Library} from './UniswapV2Library.sol';
import {RouterImmutables} from '../../../base/RouterImmutables.sol';
import {Payments} from '../../Payments.sol';
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

/// @title Router for Uniswap v2 Trades
abstract contract V2SwapRouter is RouterImmutables, Permit2Payments {
    error V2TooLittleReceived();
    error V2TooMuchRequested();
    error V2InvalidPath();

    struct SwapStep {
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeInTokenIn;
        uint256 feeInTokenOut;
    }

    function _v2Swap(address[] calldata path, address recipient, address pair) private returns (SwapStep[] memory swapSteps) {
        unchecked {
            if (path.length < 2) revert V2InvalidPath();

            swapSteps = new SwapStep[](path.length - 1);
            (address token0,) = UniswapV2Library.sortTokens(path[0], path[1]);
            uint256 finalPairIndex = path.length - 1;
            uint256 penultimatePairIndex = finalPairIndex - 1;

            for (uint256 i; i < finalPairIndex; i++) {
                (address input, address output) = (path[i], path[i + 1]);
                (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(pair).getReserves();
                (uint256 reserveIn, uint256 reserveOut) =
                    input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);

                uint256 amountInput = ERC20(input).balanceOf(pair) - reserveIn;
                uint256 amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveIn, reserveOut);

                // Calculate fee in input token (0.3% fee)
                uint256 feeInTokenIn = amountInput * 3 / 1000;

                // Calculate fee in output token
                uint256 amountInWithFee = amountInput * 997;
                uint256 numerator = amountInWithFee * reserveOut;
                uint256 denominator = reserveIn * 1000 + amountInWithFee;
                uint256 amountOutWithoutFee = numerator / denominator;
                uint256 feeInTokenOut = amountOutWithoutFee - amountOutput;

                swapSteps[i] = SwapStep({
                    amountIn: amountInput,
                    amountOut: amountOutput,
                    feeInTokenIn: feeInTokenIn,
                    feeInTokenOut: feeInTokenOut
                });

                (uint256 amount0Out, uint256 amount1Out) =
                    input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));

                address nextPair;
                (nextPair, token0) = i < penultimatePairIndex
                    ? UniswapV2Library.pairAndToken0For(
                        UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, output, path[i + 2]
                    )
                    : (recipient, address(0));

                IUniswapV2Pair(pair).swap(amount0Out, amount1Out, nextPair, new bytes(0));
                pair = nextPair;
            }
        }
    }

    /// @notice Performs a Uniswap v2 exact input swap
    /// @param recipient The recipient of the output tokens
    /// @param amountIn The amount of input tokens for the trade
    /// @param amountOutMinimum The minimum desired amount of output tokens
    /// @param path The path of the trade as an array of token addresses
    /// @param payer The address that will be paying the input
    function v2SwapExactInput(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address[] calldata path,
        address payer
    ) internal {
        uint256 amountInHolder = amountIn;

        // Get the pool trade route from calldata path and initialize the trader balance struct
        PoolInfo[] memory tradeRoutePools = getPoolsFromPath(path);
        TraderBalanceDetails memory traderBalanceDetails = TraderBalanceDetails({
            tokenSoldBalanceBefore: getTraderTokenBalance(tx.origin, path[0]),
            tokenSoldBalanceAfter: 0,
            tokenBoughtBalanceBefore: getTraderTokenBalance(tx.origin, path[path.length - 1]),
            tokenBoughtBalanceAfter: 0
        });

        address firstPair =
            UniswapV2Library.pairFor(UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, path[0], path[1]);
        if (
            amountIn != Constants.ALREADY_PAID // amountIn of 0 to signal that the pair already has the tokens
        ) {
            uint256 payerBalanceBefore = ERC20(path[0]).balanceOf(payer);
            payOrPermit2Transfer(path[0], payer, firstPair, amountIn);
            uint256 payerBalanceAfter = ERC20(path[0]).balanceOf(payer);
            amountInHolder = payerBalanceBefore - payerBalanceAfter;
        }

        ERC20 tokenOut = ERC20(path[path.length - 1]);
        uint256 balanceBefore = tokenOut.balanceOf(recipient);

        SwapStep[] memory swapSteps = _v2Swap(path, recipient, firstPair);

        uint256 amountOut = tokenOut.balanceOf(recipient) - balanceBefore;
        if (amountOut < amountOutMinimum) revert V2TooLittleReceived();

        uint256 amountSoldUsd = getUSDAmount(path[0], path[path.length - 1], amountInHolder, amountOut);

        // Populate structs
        ExchangeInfo memory exchangeInfo = getExchangeInfoV2();
        TokenInfo memory tokenSoldInfo = getTokenInfo(path[0]);
        TokenInfo memory tokenBoughtInfo = getTokenInfo(path[path.length - 1]);

        // Check before subtracting in case we underflow
        if (traderBalanceDetails.tokenSoldBalanceBefore >= amountInHolder) {
            traderBalanceDetails.tokenSoldBalanceAfter = traderBalanceDetails.tokenSoldBalanceBefore - amountInHolder;
        } else {
            traderBalanceDetails.tokenSoldBalanceAfter = 0;
        }

        traderBalanceDetails.tokenBoughtBalanceAfter = traderBalanceDetails.tokenBoughtBalanceBefore + amountOut;

        // Calculate swap fees
        uint256[] memory swapFees = new uint256[](swapSteps.length);
        uint256[] memory swapFeesUSD = new uint256[](swapSteps.length);

        for (uint i = 0; i < swapSteps.length; i++) {
            swapFees[i] = swapSteps[i].feeInTokenIn;
            swapFeesUSD[i] = getUSDAmount(path[i], path[i+1], swapSteps[i].feeInTokenIn, swapSteps[i].feeInTokenOut);
        }

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

    /// @notice Performs a Uniswap v2 exact output swap
    /// @param recipient The recipient of the output tokens
    /// @param amountOut The amount of output tokens to receive for the trade
    /// @param amountInMaximum The maximum desired amount of input tokens
    /// @param path The path of the trade as an array of token addresses
    /// @param payer The address that will be paying the input
    function v2SwapExactOutput(
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        address[] calldata path,
        address payer
    ) internal {
        // Get the pool trade route from calldata path and initialize the trader balance struct
        PoolInfo[] memory tradeRoutePools = getPoolsFromPath(path);
        TraderBalanceDetails memory traderBalanceDetails = TraderBalanceDetails({
            tokenSoldBalanceBefore: getTraderTokenBalance(tx.origin, path[0]),
            tokenSoldBalanceAfter: 0,
            tokenBoughtBalanceBefore: getTraderTokenBalance(tx.origin, path[path.length - 1]),
            tokenBoughtBalanceAfter: 0
        });

        (uint256 amountIn, address firstPair) =
            UniswapV2Library.getAmountInMultihop(UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, amountOut, path);
        if (amountIn > amountInMaximum) revert V2TooMuchRequested();

        payOrPermit2Transfer(path[0], payer, firstPair, amountIn);

        SwapStep[] memory swapSteps = _v2Swap(path, recipient, firstPair);

        uint256 amountSoldUsd = getUSDAmount(path[0], path[path.length - 1], amountIn, amountOut);

        // Populate structs
        ExchangeInfo memory exchangeInfo = getExchangeInfoV2();
        TokenInfo memory tokenSoldInfo = getTokenInfo(path[0]);
        TokenInfo memory tokenBoughtInfo = getTokenInfo(path[path.length - 1]);

        // Check before subtracting in case we underflow
        if (traderBalanceDetails.tokenSoldBalanceBefore >= amountIn) {
            traderBalanceDetails.tokenSoldBalanceAfter = traderBalanceDetails.tokenSoldBalanceBefore - amountIn;
        } else {
            traderBalanceDetails.tokenSoldBalanceAfter = 0;
        }

        traderBalanceDetails.tokenBoughtBalanceAfter = traderBalanceDetails.tokenBoughtBalanceBefore + amountOut;

        // Calculate swap fees
        uint256[] memory swapFees = new uint256[](swapSteps.length);
        uint256[] memory swapFeesUSD = new uint256[](swapSteps.length);

        for (uint i = 0; i < swapSteps.length; i++) {
            swapFees[i] = swapSteps[i].feeInTokenIn;
            swapFeesUSD[i] = getUSDAmount(path[i], path[i+1], swapSteps[i].feeInTokenIn, swapSteps[i].feeInTokenOut);
        }

        // Emit shadow event
        emit Trade(
            tx.origin,
            amountSoldUsd,
            exchangeInfo,
            amountIn,
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

    /// @dev helper function to populate ExchangeInfo struct
    function getExchangeInfoV2() private view returns (ExchangeInfo memory) {
        return ExchangeInfo({
            projectName: 'Uniswap',
            projectVersion: 'UniversalRouter',
            projectVersionDetails: 'V2SwapRouter',
            contractAddress: address(this)
        });
    }

    /// @dev helper function to populate PoolInfo struct
    function getPoolInfoV2(address poolAddress) internal view returns (PoolInfo memory) {
        IUniswapV2Pair pair = IUniswapV2Pair(poolAddress);

        TokenInfo memory token0Info = getTokenInfo(pair.token0());
        TokenInfo memory token1Info = getTokenInfo(pair.token1());

        PoolInfo memory poolInfo;
        poolInfo.token0 = token0Info;
        poolInfo.token1 = token1Info;
        poolInfo.poolAddress = poolAddress;
        poolInfo.poolFee = 3000; // The pool's fee in hundredths of a bip, i.e. 1e-6. All UniswapV2 pools are hardcoded with a 30bps fee.
        poolInfo.tickSpacing = 0; // UniswapV2 pools do not have ticks, so this is always hardcoded to 0.
        return poolInfo;
    }

    /// @dev helper function to get the pools from the path
    function getPoolsFromPath(address[] memory path) private view returns (PoolInfo[] memory) {
        PoolInfo[] memory pools = new PoolInfo[](path.length - 1);
        for (uint256 i = 0; i < path.length - 1; i++) {
            address poolAddress =
                UniswapV2Library.pairFor(UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, path[i], path[i + 1]);
            pools[i] = getPoolInfoV2(poolAddress);
        }
        return pools;
    }
}
