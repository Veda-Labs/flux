// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {FluxManager, FixedPointMathLib, SafeCast} from "src/managers/FluxManager.sol";
import {LiquidityAmounts} from "@uni-v3-p/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uni-v3-c/libraries/TickMath.sol";
import {IPositionManager} from "@uni-v4-p/interfaces/IPositionManager.sol";
import {IV4Router} from "@uni-v4-p/interfaces/IV4Router.sol";
import {IUniversalRouter} from "src/interfaces/IUniversalRouter.sol";
import {Actions} from "@uni-v4-p/libraries/Actions.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {WETH} from "@solmate/src/tokens/WETH.sol";
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

    struct ConstructorArgs {
        address owner;
        address boringVault;
        address token0;
        address token1;
        bool baseIn0Or1;
        address nativeWrapper;
        address datum;
        uint16 datumLowerBound;
        uint16 datumUpperBound;
        address positionManager;
        address universalRouter;
        address hook;
        uint24 poolFee;
        int24 tickSpacing;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTANTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes4 internal constant PERMIT2_APPROVE_SELECTOR =
        bytes4(keccak256(abi.encodePacked("approve(address,address,uint160,uint48)")));
    uint16 internal constant MIN_REBALANCE_DEVIATION = 0.9e4;
    uint16 internal constant MAX_REBALANCE_DEVIATION = 1.1e4;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STATE                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address public hook;
    uint24 public poolFee;
    int24 public tickSpacing;
    uint16 public rebalanceDeviationMin;
    uint16 public rebalanceDeviationMax;
    mapping(address => bool) internal aggregators;

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
    error UniswapV4FluxManager__BadRebalanceDeviation();
    error UniswapV4FluxManager__SwapAggregatorBadToken0();
    error UniswapV4FluxManager__SwapAggregatorBadToken1();
    error UniswapV4FluxManager__InvalidAggregator();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event AggregatorSet(address indexed aggregator, bool isAggregator);
    event RebalanceDeviationSet(uint256 min, uint256 max);
    event Rebalanced();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       IMMUTABLES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    IPositionManager internal immutable positionManager;
    address internal immutable universalRouter;

    constructor(ConstructorArgs memory _args)
        FluxManager(
            _args.owner,
            _args.boringVault,
            _args.token0,
            _args.token1,
            _args.baseIn0Or1,
            _args.nativeWrapper,
            _args.datum,
            _args.datumLowerBound,
            _args.datumUpperBound
        )
    {
        positionManager = IPositionManager(_args.positionManager);
        universalRouter = _args.universalRouter;
        hook = _args.hook;
        poolFee = _args.poolFee;
        tickSpacing = _args.tickSpacing;

        // Set to sensible defaults.
        rebalanceDeviationMin = 0.99e4;
        rebalanceDeviationMax = 1.01e4;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    ADMIN FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setAggregator(address _aggregator, bool _isAggregator) external requiresAuth {
        aggregators[_aggregator] = _isAggregator;
        emit AggregatorSet(_aggregator, _isAggregator);
    }

    function setRebalanceDeviations(uint16 min, uint16 max) external requiresAuth {
        if (min > BPS_SCALE || min < MIN_REBALANCE_DEVIATION || max < BPS_SCALE || max > MAX_REBALANCE_DEVIATION) {
            revert UniswapV4FluxManager__BadRebalanceDeviation();
        }
        rebalanceDeviationMin = min;
        rebalanceDeviationMax = max;

        emit RebalanceDeviationSet(min, max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     FLUX FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Refresh internal flux constants.
    /// @dev For Uniswap V4 this is token0 and token1 contract balances
    function _refreshInternalFluxAccounting() internal override {
        token0Balance = address(token0) == address(0)
            ? SafeCast.toUint128(ERC20(nativeWrapper).balanceOf(address(boringVault)))
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
        if (address(token0) == address(0)) {
            _unwrapAllNative();
        }
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
                (uint128 amount0In, uint128 minAmount1Out, uint256 deadline, bytes memory hookData) =
                    abi.decode(action.data, (uint128, uint128, uint256, bytes));
                _swapToken0ForToken1InPool(amount0In, minAmount1Out, deadline, hookData);
            } else if (action.kind == ActionKind.SWAP_TOKEN1_FOR_TOKEN0_IN_POOL) {
                (uint128 amount1In, uint128 minAmount0Out, uint256 deadline, bytes memory hookData) =
                    abi.decode(action.data, (uint128, uint128, uint256, bytes));
                _swapToken0ForToken1InPool(amount1In, minAmount0Out, deadline, hookData);
            } else if (action.kind == ActionKind.SWAP_WITH_AGGREGATOR) {
                (address aggregator, uint256 amount, bool token0Or1, uint256 minAmountOut, bytes memory swapData) =
                    abi.decode(action.data, (address, uint256, bool, uint256, bytes));
                _swapWithAggregator(aggregator, amount, token0Or1, minAmountOut, swapData);
            }
        }
        if (address(token0) == address(0)) {
            _wrapAllNative();
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

        // Fee Calculations
        if (totalAssetsInBaseAfter > totalAssetsInBaseBefore) {
            // We made a profit, need to take fees
            uint256 profit = totalAssetsInBaseAfter - totalAssetsInBaseBefore;
            pendingFee += SafeCast.toUint128(profit.mulDivDown(performanceFee, BPS_SCALE));
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
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), poolFee, tickSpacing, IHooks(hook));

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

    function _swapToken0ForToken1InPool(
        uint128 amount0In,
        uint128 minAmount1Out,
        uint256 deadline,
        bytes memory hookData
    ) internal {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);

        PoolKey memory poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), poolFee, tickSpacing, IHooks(hook));

        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true, // true if we're swapping token0 for token1
                amountIn: amount0In, // amount of tokens we're swapping
                amountOutMinimum: minAmount1Out, // minimum amount we expect to receive
                hookData: hookData // depends on the hook
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

    function _swapToken1ForToken0InPool(
        uint128 amount1In,
        uint128 minAmount0Out,
        uint256 deadline,
        bytes memory hookData
    ) internal {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);

        PoolKey memory poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), poolFee, tickSpacing, IHooks(hook));

        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false, // false if we're swapping token1 for token0
                amountIn: amount1In, // amount of tokens we're swapping
                amountOutMinimum: minAmount0Out, // minimum amount we expect to receive
                hookData: hookData // depends on the hook
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

    function _swapWithAggregator(
        address aggregator,
        uint256 amount,
        bool token0Or1,
        uint256 minAmountOut,
        bytes memory swapData
    ) internal {
        // check that the aggregator is a valid aggregator
        if (aggregators[aggregator] == false) revert UniswapV4FluxManager__InvalidAggregator();
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

        boringVault.manage(aggregator, swapData, token0Or1 && address(token0) == address(0) ? amount : 0);

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

    function _wrapAllNative() internal {
        if (address(boringVault).balance != 0) {
            boringVault.manage(
                nativeWrapper, abi.encodeWithSelector(WETH.deposit.selector), address(boringVault).balance
            );
        }
    }

    function _unwrapAllNative() internal {
        if (ERC20(nativeWrapper).balanceOf(address(boringVault)) != 0) {
            // Unwrap all native tokens to the boring vault.
            boringVault.manage(
                nativeWrapper,
                abi.encodeWithSelector(WETH.withdraw.selector, ERC20(nativeWrapper).balanceOf(address(boringVault))),
                0
            );
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
