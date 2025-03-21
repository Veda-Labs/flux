// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {FluxManager, FixedPointMathLib, SafeCast} from "src/FluxManager.sol";
import {LiquidityAmounts} from "@uni-v3-p/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uni-v3-c/libraries/TickMath.sol";
import {IPositionManager} from "@uni-v4-p/interfaces/IPositionManager.sol";
import {IV4Router} from "@uni-v4-p/interfaces/IV4Router.sol";
import {IUniversalRouter} from "src/interfaces/IUniversalRouter.sol";
import {Actions} from "@uni-v4-p/libraries/Actions.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {FullMath} from "@uni-v4-c/libraries/FullMath.sol";
import {Commands} from "src/libraries/Commands.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {console} from "@forge-std/Test.sol";

contract UniswapV4FluxManager is FluxManager {
    using FixedPointMathLib for uint256;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ENUMS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    enum ActionKind {
        TOKEN0_APPROVE_PERMIT_2,
        TOKEN1_APPROVE_PERMIT_2,
        TOKEN0_PERMIT_2_APPROVE_POSITION_MANAGER,
        TOKEN1_PERMIT_2_APPROVE_POSITION_MANAGER,
        TOKEN0_PERMIT_2_APPROVE_UNIVERSAL_ROUTER,
        TOKEN1_PERMIT_2_APPROVE_UNIVERSAL_ROUTER,
        MINT,
        BURN,
        INCREASE_LIQUIDITY,
        DECREASE_LIQUIDITY,
        COLLECT_FEES,
        SWAP_TOKEN0_FOR_TOKEN1_IN_POOL,
        SWAP_TOKEN1_FOR_TOKEN0_IN_POOL,
        SWAP_WITH_AGGREGATOR
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STRUCT                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct Action {
        ActionKind kind;
        bytes data;
    }

    struct PositionData {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTANTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint128 internal constant REFERENCE_LIQUIDITY = 1_000_000_000;
    int24 internal constant MIN_TICK = -887_270;
    int24 internal constant MAX_TICK = 887_270;
    bytes4 internal constant PERMIT2_APPROVE_SELECTOR =
        bytes4(keccak256(abi.encodePacked("approve(address,address,uint160,uint48)")));
    uint16 internal constant MIN_REBALANCE_DEVIATION = 0.9e4;
    uint16 internal constant MAX_REBALANCE_DEVIATION = 1.1e4;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STATE                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint16 public rebalanceDeviationMin;
    uint16 public rebalanceDeviationMax;
    int24 public referenceTickLower;
    int24 public referenceTickUpper;
    address internal aggregator;

    uint128 internal token0Balance;
    uint128 internal token1Balance;

    uint256[] public trackedPositions;

    PositionData[] internal trackedPositionData;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error UniswapV4FluxManager__PositionNotFound();
    error UniswapV4FluxManager__RebalanceDeviation(uint256 result, uint256 min, uint256 max);
    error UniswapV4FluxManager__RebalanceChangedTotalSupply();
    error UniswapV4FluxManager__BadReferenceTick();
    error UniswapV4FluxManager__BadRebalanceDeviation();
    error UniswapV4FluxManager__SwapAggregatorBadToken0();
    error UniswapV4FluxManager__SwapAggregatorBadToken1();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event ReferenceTicksSet();
    event AggregatorSet();
    event RebalanceDeviationSet();
    event Rebalanced();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       IMMUTABLES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    IPositionManager internal immutable positionManager;
    address internal immutable universalRouter;

    constructor(
        address _owner,
        address _boringVault,
        address _token0,
        address _token1,
        bool _baseIn0Or1,
        address _nativeWrapper,
        address _datum,
        uint16 _datumLowerBound,
        uint16 _datumUpperBound,
        address _positionManager,
        address _universalRouter
    )
        FluxManager(
            _owner,
            _boringVault,
            _token0,
            _token1,
            _baseIn0Or1,
            _nativeWrapper,
            _datum,
            _datumLowerBound,
            _datumUpperBound
        )
    {
        positionManager = IPositionManager(_positionManager);
        universalRouter = _universalRouter;

        referenceTickLower = MIN_TICK;
        referenceTickUpper = MAX_TICK;

        // Set to sensible defaults.
        rebalanceDeviationMin = 0.99e4;
        rebalanceDeviationMax = 1.01e4;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    ADMIN FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setAggregator(address _aggregator) external requiresAuth {
        aggregator = _aggregator;
        emit AggregatorSet();
    }

    function setReferenceTicks(int24 newLower, int24 newUpper, bool token0Or1) external requiresAuth {
        if (newLower >= newUpper) {
            revert UniswapV4FluxManager__BadReferenceTick();
        }
        _claimFees(token0Or1);
        // Make sure we are using Liquidity Performance Metric
        performanceMetric = PerformanceMetric.LIQUIDITY;
        referenceTickLower = newLower;
        referenceTickUpper = newUpper;
        _refreshInternalFluxAccounting();
        _resetHighWatermark();

        emit PerformanceMetricSet();
        emit ReferenceTicksSet();
    }

    function setRebalanceDeviations(uint16 min, uint16 max) external requiresAuth {
        if (min > BPS_SCALE || min < MIN_REBALANCE_DEVIATION || max < BPS_SCALE || max > MAX_REBALANCE_DEVIATION) {
            revert UniswapV4FluxManager__BadRebalanceDeviation();
        }
        rebalanceDeviationMin = min;
        rebalanceDeviationMax = max;

        emit RebalanceDeviationSet();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     FLUX FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Calculates the accumulated liquidity of a reference UniswapV4 position using given exchange rate.
    /// @dev This function determines the liquidity scalar `liquidityScalar` based on the available token balances
    ///      and the optimal token balances for a max range Uniswap V4 position. The calculation is based on the following system of equations:
    ///      - currentToken0Balance - token0SwapAmount = scaledToken0Balance * liquidityScalar
    ///      - currentToken1Balance + token0SwapAmount * exchangeRate = scaledToken1Balance * liquidityScalar
    ///      Solving these equations gives:
    ///      - liquidityScalar = (currentToken0Balance * exchangeRate + currentToken1Balance) / (scaledToken1Balance + scaledToken0Balance * exchangeRate)
    ///      The reverse case, where token0 is the limiting factor, was also checked, and the resulting liquidityScalar equation was the same.
    /// @param exchangeRate The price of token1 per token0, given in terms of token1 decimals.
    /// @custom:variable currentToken0Balance Token 0 balance, represented by `t0B`.
    /// @custom:variable token0SwapAmount The amount of token 0 that must be swapped, unknown.
    /// @custom:variable liquidityScalar The liquidity scalar, represented by `liquidityScalar`.
    /// @custom:variable currentToken1Balance Token 1 balance, represented by `t1B`.
    /// @custom:variable exchangeRate The exchange rate, represented by `exchangeRate`.
    /// @custom:variable scaledToken0Balance Optimal token 0 balance for optimal liquidity, represented by `scaledToken0Balance`.
    /// @custom:variable scaledToken1Balance Optimal token 1 balance for optimal liquidity, represented by `scaledToken1Balance`.
    function _totalLiquidity(uint256 exchangeRate) internal view override returns (uint256 accumulated) {
        // Calculate the current sqrtPrice.
        uint256 ratioX192 = FullMath.mulDiv(exchangeRate, 2 ** 192, 10 ** decimals0);
        uint160 sqrtPriceX96 = SafeCast.toUint160(_sqrt(ratioX192));
        uint160 lowerSqrtPriceX96 = TickMath.getSqrtRatioAtTick(referenceTickLower);
        uint160 upperSqrtPriceX96 = TickMath.getSqrtRatioAtTick(referenceTickUpper);

        (uint256 t0B, uint256 t1B) = _totalAssets(exchangeRate);
        if (sqrtPriceX96 <= lowerSqrtPriceX96) {
            // Reference position is out of range.
            // Convert all token1 to token0
            uint256 total = t0B + t1B.mulDivDown(10 ** decimals0, exchangeRate);
            accumulated = LiquidityAmounts.getLiquidityForAmount0(lowerSqrtPriceX96, upperSqrtPriceX96, total);
        } else if (sqrtPriceX96 < upperSqrtPriceX96) {
            // Reference position is in range
            (uint256 scaledToken0Balance, uint256 scaledToken1Balance) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, lowerSqrtPriceX96, upperSqrtPriceX96, REFERENCE_LIQUIDITY
            );

            // The math has spoken and it actually does not matter if token0 or token1 is limiting the resulting
            // liquidity scalar equation is the same, so no need to check what is limiting.
            uint256 liquidityScalarNumerator = t0B.mulDivDown(exchangeRate, 10 ** decimals0) + t1B;
            uint256 liquidityScalarDenominator =
                scaledToken0Balance.mulDivDown(exchangeRate, 10 ** decimals0) + scaledToken1Balance;
            // accumulatedLiquidity = numerator * REFERENCE_LIQUIDITY / denominator
            accumulated = FullMath.mulDiv(liquidityScalarNumerator, REFERENCE_LIQUIDITY, liquidityScalarDenominator);
        } else {
            // Reference position is out of range.
            // Convert all token0 to token1
            uint256 total = t1B + t0B.mulDivDown(exchangeRate, 10 ** decimals0);
            accumulated = LiquidityAmounts.getLiquidityForAmount1(lowerSqrtPriceX96, upperSqrtPriceX96, total);
        }
    }

    function _convertLiquidityToToken(uint256 exchangeRate, uint128 liquidity, bool token0Or1)
        internal
        view
        override
        returns (uint256 amount)
    {
        // Calculate the current sqrtPrice.
        uint256 ratioX192 = FullMath.mulDiv(exchangeRate, 2 ** 192, 10 ** decimals0);
        uint160 sqrtPriceX96 = SafeCast.toUint160(_sqrt(ratioX192));

        (uint256 t0B, uint256 t1B) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(referenceTickLower),
            TickMath.getSqrtRatioAtTick(referenceTickUpper),
            liquidity
        );

        // Convert into 1 token.
        if (token0Or1) {
            amount = t0B + t1B.mulDivDown(10 ** decimals0, exchangeRate);
        } else {
            amount = t1B + t0B.mulDivDown(exchangeRate, 10 ** decimals0);
        }
    }

    /// @notice Refresh internal flux constants.
    /// @dev For Uniswap V4 this is token0 and token1 contract balances
    function _refreshInternalFluxAccounting() internal override {
        token0Balance = address(token0) == address(0)
            ? SafeCast.toUint128(address(boringVault).balance)
            : SafeCast.toUint128(token0.balanceOf(address(boringVault)));
        token1Balance = SafeCast.toUint128(token1.balanceOf(address(boringVault)));
    }

    /// @notice exchangeRate must be given in terms of token1 decimals, and it should be the amount of token1 per token0
    function _totalAssets(uint256 exchangeRate)
        internal
        view
        override
        returns (uint256 token0Assets, uint256 token1Assets)
    {
        token0Assets = token0Balance;
        token1Assets = token1Balance;

        // Calculate the current sqrtPrice.
        uint256 ratioX192 = FullMath.mulDiv(exchangeRate, 2 ** 192, 10 ** decimals0);
        uint160 sqrtPriceX96 = SafeCast.toUint160(_sqrt(ratioX192));

        // Iterate through tracked position data and aggregate token balances
        uint256 positionCount = trackedPositionData.length;
        for (uint256 i; i < positionCount; ++i) {
            PositionData memory data = trackedPositionData[i];
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(data.tickLower),
                TickMath.getSqrtRatioAtTick(data.tickUpper),
                data.liquidity
            );
            token0Assets += amount0;
            token1Assets += amount1;
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  STRATEGIST FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function rebalance(uint256 exchangeRate, Action[] calldata actions)
        external
        checkDatum(exchangeRate)
        requiresAuth
    {
        _refreshInternalFluxAccounting();
        uint256 totalSupplyBefore = boringVault.totalSupply();
        uint256 totalAssetsInBaseBefore = totalAssets(exchangeRate, baseIn0Or1);
        for (uint256 i; i < actions.length; ++i) {
            Action calldata action = actions[i];
            if (action.kind == ActionKind.TOKEN0_APPROVE_PERMIT_2) {
                uint256 amount = abi.decode(action.data, (uint256));
                _token0ApprovePermit2(amount);
            } else if (action.kind == ActionKind.TOKEN1_APPROVE_PERMIT_2) {
                uint256 amount = abi.decode(action.data, (uint256));
                _token1ApprovePermit2(amount);
            } else if (action.kind == ActionKind.TOKEN0_PERMIT_2_APPROVE_POSITION_MANAGER) {
                (uint160 amount, uint48 deadline) = abi.decode(action.data, (uint160, uint48));
                _token0Permit2ApprovePositionManager(amount, deadline);
            } else if (action.kind == ActionKind.TOKEN1_PERMIT_2_APPROVE_POSITION_MANAGER) {
                (uint160 amount, uint48 deadline) = abi.decode(action.data, (uint160, uint48));
                _token1Permit2ApprovePositionManager(amount, deadline);
            } else if (action.kind == ActionKind.TOKEN0_PERMIT_2_APPROVE_UNIVERSAL_ROUTER) {
                (uint160 amount, uint48 deadline) = abi.decode(action.data, (uint160, uint48));
                _token0Permit2ApproveUniversalRouter(amount, deadline);
            } else if (action.kind == ActionKind.TOKEN1_PERMIT_2_APPROVE_UNIVERSAL_ROUTER) {
                (uint160 amount, uint48 deadline) = abi.decode(action.data, (uint160, uint48));
                _token1Permit2ApproveUniversalRouter(amount, deadline);
            } else if (action.kind == ActionKind.MINT) {
                (
                    int24 tickLower,
                    int24 tickUpper,
                    uint128 liquidity,
                    uint256 amount0Max,
                    uint256 amount1Max,
                    uint256 deadline
                ) = abi.decode(action.data, (int24, int24, uint128, uint256, uint256, uint256));
                _mint(tickLower, tickUpper, liquidity, amount0Max, amount1Max, deadline);
            } else if (action.kind == ActionKind.BURN) {
                (uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) =
                    abi.decode(action.data, (uint256, uint256, uint256, uint256));
                _burn(positionId, amount0Min, amount1Min, deadline);
            } else if (action.kind == ActionKind.INCREASE_LIQUIDITY) {
                (uint256 positionId, uint128 liquidity, uint256 amount0Max, uint256 amount1Max, uint256 deadline) =
                    abi.decode(action.data, (uint256, uint128, uint256, uint256, uint256));
                _increaseLiquidity(positionId, liquidity, amount0Max, amount1Max, deadline);
            } else if (action.kind == ActionKind.DECREASE_LIQUIDITY) {
                (uint256 positionId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min, uint256 deadline) =
                    abi.decode(action.data, (uint256, uint128, uint256, uint256, uint256));
                _decreaseLiquidity(positionId, liquidity, amount0Min, amount1Min, deadline);
            } else if (action.kind == ActionKind.COLLECT_FEES) {
                (uint256 positionId, uint256 deadline) = abi.decode(action.data, (uint256, uint256));
                _collectFees(positionId, deadline);
            } else if (action.kind == ActionKind.SWAP_TOKEN0_FOR_TOKEN1_IN_POOL) {
                (uint128 amount0In, uint128 minAmount1Out, uint256 deadline) =
                    abi.decode(action.data, (uint128, uint128, uint256));
                _swapToken0ForToken1InPool(amount0In, minAmount1Out, deadline);
            } else if (action.kind == ActionKind.SWAP_TOKEN1_FOR_TOKEN0_IN_POOL) {
                (uint128 amount1In, uint128 minAmount0Out, uint256 deadline) =
                    abi.decode(action.data, (uint128, uint128, uint256));
                _swapToken0ForToken1InPool(amount1In, minAmount0Out, deadline);
            } else if (action.kind == ActionKind.SWAP_WITH_AGGREGATOR) {
                (uint256 amount, bool token0Or1, uint256 minAmountOut, bytes memory swapData) =
                    abi.decode(action.data, (uint256, bool, uint256, bytes));
                _swapWithAggregator(amount, token0Or1, minAmountOut, swapData);
            }
        }

        _refreshInternalFluxAccounting();

        // Make sure totalSupply is constant.
        if (totalSupplyBefore != boringVault.totalSupply()) revert UniswapV4FluxManager__RebalanceChangedTotalSupply();

        // Check rebalance deviation
        uint256 totalAssetsInBaseAfter = totalAssets(exchangeRate, baseIn0Or1);
        uint256 minAssets = totalAssetsInBaseBefore.mulDivDown(rebalanceDeviationMin, BPS_SCALE);
        uint256 maxAssets = totalAssetsInBaseBefore.mulDivDown(rebalanceDeviationMax, BPS_SCALE);
        if (totalAssetsInBaseAfter < minAssets || totalAssetsInBaseAfter > maxAssets) {
            revert UniswapV4FluxManager__RebalanceDeviation(totalAssetsInBaseAfter, minAssets, maxAssets);
        }

        emit Rebalanced();
    }

    function _token0ApprovePermit2(uint256 amount) internal {
        bytes memory approveData = abi.encodeWithSelector(ERC20.approve.selector, PERMIT2, amount);
        boringVault.manage(address(token0), approveData, 0);
    }

    function _token1ApprovePermit2(uint256 amount) internal {
        bytes memory approveData = abi.encodeWithSelector(ERC20.approve.selector, PERMIT2, amount);
        boringVault.manage(address(token1), approveData, 0);
    }

    function _token0Permit2ApprovePositionManager(uint160 amount, uint48 deadline) internal {
        bytes memory approveData =
            abi.encodeWithSelector(PERMIT2_APPROVE_SELECTOR, token0, positionManager, amount, deadline);
        boringVault.manage(PERMIT2, approveData, 0);
    }

    function _token1Permit2ApprovePositionManager(uint160 amount, uint48 deadline) internal {
        bytes memory approveData =
            abi.encodeWithSelector(PERMIT2_APPROVE_SELECTOR, token1, positionManager, amount, deadline);
        boringVault.manage(PERMIT2, approveData, 0);
    }

    function _token0Permit2ApproveUniversalRouter(uint160 amount, uint48 deadline) internal {
        bytes memory approveData =
            abi.encodeWithSelector(PERMIT2_APPROVE_SELECTOR, token0, universalRouter, amount, deadline);
        boringVault.manage(PERMIT2, approveData, 0);
    }

    function _token1Permit2ApproveUniversalRouter(uint160 amount, uint48 deadline) internal {
        bytes memory approveData =
            abi.encodeWithSelector(PERMIT2_APPROVE_SELECTOR, token1, universalRouter, amount, deadline);
        boringVault.manage(PERMIT2, approveData, 0);
    }

    // We always sweep becuase this logic does not attempt to account for value sitting unallocated in UniV4
    function _mint(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        PoolKey memory poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 500, 10, IHooks(address(0)));

        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, boringVault, hex"");
        params[1] = abi.encode(token0, token1);
        params[2] = abi.encode(token0, boringVault);
        params[3] = abi.encode(token1, boringVault);
        uint256 positionId = positionManager.nextTokenId();
        _modifyLiquidities(actions, params, deadline, address(token0) == address(0) ? amount0Max : 0);

        // Track new position.
        trackedPositions.push(positionId);
        trackedPositionData.push(PositionData(liquidity, tickLower, tickUpper));
    }

    function _burn(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) internal {
        // Remove position from tracking if present.
        _removePositionIfPresent(positionId);

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, amount0Min, amount1Min, hex"");
        params[1] = abi.encode(token0, token1, boringVault);

        _modifyLiquidities(actions, params, deadline, 0);
    }

    function _increaseLiquidity(
        uint256 positionId,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);

        params[0] = abi.encode(positionId, liquidity, amount0Max, amount1Max, hex"");
        params[1] = abi.encode(token0, token1);
        params[2] = abi.encode(token0, boringVault);
        params[3] = abi.encode(token1, boringVault);

        _modifyLiquidities(actions, params, deadline, address(token0) == address(0) ? amount0Max : 0);

        _incrementLiquidity(positionId, liquidity);
    }

    function _decreaseLiquidity(
        uint256 positionId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(positionId, liquidity, amount0Min, amount1Min, hex"");
        params[1] = abi.encode(token0, token1, boringVault);

        _modifyLiquidities(actions, params, deadline, 0);

        _decrementLiquidity(positionId, liquidity);
    }

    function _collectFees(uint256 positionId, uint256 deadline) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, 0, 0, 0, hex"");
        params[1] = abi.encode(token0, token1, boringVault);

        _modifyLiquidities(actions, params, deadline, 0);
    }

    function _swapToken0ForToken1InPool(uint128 amount0In, uint128 minAmount1Out, uint256 deadline) internal {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);

        PoolKey memory poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 500, 10, IHooks(address(0)));

        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true, // true if we're swapping token0 for token1
                amountIn: amount0In, // amount of tokens we're swapping
                amountOutMinimum: minAmount1Out, // minimum amount we expect to receive
                hookData: bytes("") // no hook data needed
            })
        );
        params[1] = abi.encode(token0, amount0In);
        params[2] = abi.encode(token1, minAmount1Out);

        // Combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        bytes memory swapData = abi.encodeWithSelector(IUniversalRouter.execute.selector, commands, inputs, deadline);

        boringVault.manage(universalRouter, swapData, address(token0) == address(0) ? amount0In : 0);
    }

    function _swapToken1ForToken0InPool(uint128 amount1In, uint128 minAmount0Out, uint256 deadline) internal {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);

        PoolKey memory poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 500, 10, IHooks(address(0)));

        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false, // false if we're swapping token1 for token0
                amountIn: amount1In, // amount of tokens we're swapping
                amountOutMinimum: minAmount0Out, // minimum amount we expect to receive
                hookData: bytes("") // no hook data needed
            })
        );
        params[1] = abi.encode(token1, amount1In);
        params[2] = abi.encode(token0, minAmount0Out);

        // Combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        bytes memory swapData = abi.encodeWithSelector(IUniversalRouter.execute.selector, commands, inputs, deadline);

        boringVault.manage(universalRouter, swapData, 0);
    }

    function _swapWithAggregator(uint256 amount, bool token0Or1, uint256 minAmountOut, bytes memory swapData)
        internal
    {
        bytes memory approveCalldata = abi.encodeWithSelector(ERC20.approve.selector, aggregator, amount);
        if (token0Or1) {
            // Approve the aggregator to spend tokens.
            if (address(token0) != address(0)) {
                boringVault.manage(address(token0), approveCalldata, 0);
            }
        } else {
            boringVault.manage(address(token1), approveCalldata, 0);
        }

        uint256 token0Starting =
            address(token0) == address(0) ? address(boringVault).balance : token0.balanceOf(address(boringVault));
        uint256 token1Starting = token1.balanceOf(address(boringVault));

        boringVault.manage(aggregator, swapData, token0Or1 ? amount : 0);

        uint256 token0Ending =
            address(token0) == address(0) ? address(boringVault).balance : token0.balanceOf(address(boringVault));
        uint256 token1Ending = token1.balanceOf(address(boringVault));

        // no need to check that entire approval was used as we revert if the input token balance is not decremented by amount.
        if (token0Or1) {
            if ((token0Starting - token0Ending) != amount) revert UniswapV4FluxManager__SwapAggregatorBadToken0();
            if ((token1Ending - token1Starting) < minAmountOut) revert UniswapV4FluxManager__SwapAggregatorBadToken1();
        } else {
            if ((token1Starting - token1Ending) != amount) revert UniswapV4FluxManager__SwapAggregatorBadToken1();
            if ((token0Ending - token0Starting) < minAmountOut) revert UniswapV4FluxManager__SwapAggregatorBadToken0();
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   INTERNAL FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _modifyLiquidities(bytes memory actions, bytes[] memory params, uint256 deadline, uint256 value)
        internal
    {
        bytes memory data =
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, abi.encode(actions, params), deadline);

        boringVault.manage(address(positionManager), data, value);
    }

    function _incrementLiquidity(uint256 positionId, uint128 liquidity) internal {
        uint256 positionCount = trackedPositions.length;
        uint256 positionIndex = type(uint256).max;
        for (uint256 i; i < positionCount; ++i) {
            if (positionId == trackedPositions[i]) {
                positionIndex = i;
                break;
            }
        }

        if (positionIndex != type(uint256).max) {
            trackedPositionData[positionIndex].liquidity += liquidity;
        } else {
            revert UniswapV4FluxManager__PositionNotFound();
        }
    }

    function _decrementLiquidity(uint256 positionId, uint128 liquidity) internal {
        uint256 positionCount = trackedPositions.length;
        uint256 positionIndex = type(uint256).max;
        for (uint256 i; i < positionCount; ++i) {
            if (positionId == trackedPositions[i]) {
                positionIndex = i;
                break;
            }
        }

        if (positionIndex != type(uint256).max) {
            trackedPositionData[positionIndex].liquidity -= liquidity;
        } else {
            revert UniswapV4FluxManager__PositionNotFound();
        }
    }

    function _removePositionIfPresent(uint256 positionId) internal {
        uint256 positionCount = trackedPositions.length;
        uint256 positionIndex = type(uint256).max;
        for (uint256 i; i < positionCount; ++i) {
            if (positionId == trackedPositions[i]) {
                positionIndex = i;
                break;
            }
        }

        if (positionIndex != type(uint256).max) {
            // Position was found, remove from tracked positions and data.
            trackedPositions[positionIndex] = trackedPositions[positionCount - 1];
            trackedPositionData[positionIndex] = trackedPositionData[positionCount - 1];
            trackedPositions.pop();
            trackedPositionData.pop();
        }
    }

    /// @notice Calculates the square root of the input.
    function _sqrt(uint256 _x) internal pure returns (uint256 y) {
        uint256 z = (_x + 1) / 2;
        y = _x;
        while (z < y) {
            y = z;
            z = (_x / z + z) / 2;
        }
    }
}
