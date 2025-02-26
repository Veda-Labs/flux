// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {FluxManager, FixedPointMathLib, SafeCast} from "src/FluxManager.sol";
import {LiquidityAmounts} from "@uni-v3-p/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uni-v3-c/libraries/TickMath.sol";
import {IPositionManager} from "@uni-v4-p/interfaces/IPositionManager.sol";
import {Actions} from "@uni-v4-p/libraries/Actions.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {FullMath} from "@uni-v4-c/libraries/FullMath.sol";

import {console} from "@forge-std/Test.sol";

contract UniswapV4FluxManager is FluxManager {
    using FixedPointMathLib for uint256;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STRUCT                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct PoolKey {
        /// @notice The lower currency of the pool, sorted numerically
        address currency0;
        /// @notice The higher currency of the pool, sorted numerically
        address currency1;
        /// @notice The pool LP fee, capped at 1_000_000. If the highest bit is 1, the pool has a dynamic fee and must be exactly equal to 0x800000
        uint24 fee;
        /// @notice Ticks that involve positions must be a multiple of tick spacing
        int24 tickSpacing;
        /// @notice The hooks of the pool
        address hooks;
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
    int24 internal constant MIN_TICK = -887_270;
    int24 internal constant MAX_TICK = 887_270;
    uint128 internal constant BASE_LIQUIDITY = 1_000_000_000;
    uint256 internal constant LIQUIDITY_SCALAR_MULTIPLIER = 1e18;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STATE                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    uint128 internal token0Balance;
    uint128 internal token1Balance;

    uint256[] internal trackedPositions;

    PositionData[] internal trackedPositionData;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error UniswapV4FluxManager__PositionNotFound();
    error UniswapV4FluxManager__BadOptimal();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       IMMUTABLES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    IPositionManager internal immutable positionManager;

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
        address _positionManager
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
        bytes memory approveData = abi.encodeWithSelector(ERC20.approve.selector, PERMIT2, type(uint256).max);
        if (_token0 != address(0)) boringVault.manage(_token0, approveData, 0);
        boringVault.manage(_token1, approveData, 0);

        // TODO make this flow work for token0 being an ERC20.
        approveData = abi.encodeWithSelector(
            bytes4(keccak256(abi.encodePacked("approve(address,address,uint160,uint48)"))),
            _token1,
            _positionManager,
            type(uint160).max,
            type(uint48).max
        );
        if (_token0 != address(0)) boringVault.manage(_token0, approveData, 0);
        boringVault.manage(PERMIT2, approveData, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     FLUX FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Calculates the accumulated liquidity of a wide range UniswapV4 position using given exchange rate.
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

        (uint256 scaledToken0Balance, uint256 scaledToken1Balance) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(MIN_TICK), TickMath.getSqrtRatioAtTick(MAX_TICK), BASE_LIQUIDITY
        );

        (uint256 t0B, uint256 t1B) = _totalAssets(exchangeRate);

        // The math has spoken and it actually does not matter if token0 or token1 is limiting the resulting
        // liquidity scalar equation is the same, so no need to check what is limiting.
        uint256 liquidityScalarNumerator = t0B.mulDivDown(exchangeRate, 10 ** decimals0) + t1B;
        uint256 liquidityScalarDenominator =
            scaledToken0Balance.mulDivDown(exchangeRate, 10 ** decimals0) + scaledToken1Balance;
        // accumulatedLiquidity = numerator * BASE_LIQUIDITY / denominator
        accumulated = liquidityScalarNumerator.mulDivDown(BASE_LIQUIDITY, liquidityScalarDenominator);
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
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(MIN_TICK), TickMath.getSqrtRatioAtTick(MAX_TICK), liquidity
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

    // TODO maybe make a rebalance function that lets strategists do multiple actions at once
    // TODO Add swapping support

    // We always sweep becuase this logic does not attempt to account for value sitting unallocated in UniV4
    function mint(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external requiresAuth {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        PoolKey memory poolKey = PoolKey(address(token0), address(token1), 500, 10, address(0));

        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, boringVault, hex"");
        params[1] = abi.encode(token0, token1);
        params[2] = abi.encode(token0, boringVault);
        params[3] = abi.encode(token1, boringVault);
        uint256 positionId = positionManager.nextTokenId();
        _modifyLiquidities(actions, params, deadline, address(token0) == address(0) ? amount0Max : 0);

        // Track new position.
        trackedPositions.push(positionId);
        trackedPositionData.push(PositionData(liquidity, tickLower, tickUpper));

        _refreshInternalFluxAccounting();
    }

    function burn(uint256 positionId, uint256 amount0Min, uint256 amount1Min, uint256 deadline) external requiresAuth {
        // Remove position from tracking if present.
        _removePositionIfPresent(positionId);

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, amount0Min, amount1Min, hex"");
        params[1] = abi.encode(token0, token1, boringVault);

        _modifyLiquidities(actions, params, deadline, 0);

        _refreshInternalFluxAccounting();
    }

    function increaseLiquidity(
        uint256 positionId,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external requiresAuth {
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

        _refreshInternalFluxAccounting();
    }

    function decreaseLiquidity(
        uint256 positionId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external requiresAuth {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(positionId, liquidity, amount0Min, amount1Min, hex"");
        params[1] = abi.encode(token0, token1, boringVault);

        _modifyLiquidities(actions, params, deadline, 0);

        _decrementLiquidity(positionId, liquidity);

        _refreshInternalFluxAccounting();
    }

    function collectFees(uint256 positionId, uint256 deadline) external requiresAuth {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, 0, 0, 0, hex"");
        params[1] = abi.encode(token0, token1, boringVault);

        _modifyLiquidities(actions, params, deadline, 0);

        _refreshInternalFluxAccounting();
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
