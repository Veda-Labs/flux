// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {FluxManager, FixedPointMathLib} from "src/FluxManager.sol";
import {LiquidityAmounts} from "@uni-v3-p/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uni-v3-c/libraries/TickMath.sol";
import {IPositionManager} from "@uni-v4-p/interfaces/IPositionManager.sol";
import {Actions} from "@uni-v4-p/libraries/Actions.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
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

    uint256 internal constant PRECISION = 1e9;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STATE                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    uint128 internal token0Balance;
    uint128 internal token1Balance;

    uint256[] internal trackedPositions;

    PositionData[] internal trackedPositionData;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       IMMUTABLES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    IPositionManager internal immutable positionManager;

    constructor(address _owner, address _boringVault, address _token0, address _token1, address _positionManager)
        FluxManager(_owner, _boringVault, _token0, _token1)
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

    /// @notice Refresh internal flux constants.
    /// @dev For Uniswap V4 this is token0 and token1 contract balances
    function _refreshInternalFluxAccounting() internal override {
        // TODO safecast
        token0Balance = address(token0) == address(0)
            ? uint128(address(boringVault).balance)
            : uint128(token0.balanceOf(address(boringVault)));
        token1Balance = uint128(token1.balanceOf(address(boringVault)));
    }

    function _totalAssets(uint256 exchangeRate)
        internal
        view
        override
        returns (uint256 token0Assets, uint256 token1Assets)
    {
        token0Assets = token0Balance;
        token1Assets = token1Balance;

        // Calculate the current sqrtPrice.
        uint256 ratioX192 = PRECISION.mulDivDown((10 ** decimals1) << 192, exchangeRate);
        // TODO safecast
        uint160 sqrtPriceX96 = uint160(_sqrt(ratioX192));
        console.log("Calculated sqrtPriceX96", sqrtPriceX96);

        // Iterate through tracked position data and aggregate token balances
        uint256 positionCount = trackedPositionData.length;
        for (uint256 i; i < positionCount; ++i) {
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(trackedPositionData[i].tickLower),
                TickMath.getSqrtRatioAtTick(trackedPositionData[i].tickLower),
                trackedPositionData[i].liquidity
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
    // TODO should native pairs also be allowed to use WETH plus other asset? This is a bit weird cuz the order of token0 and 1 can change

    function mint(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external requiresAuth {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        PoolKey memory poolKey = PoolKey(address(token0), address(token1), 500, 10, address(0));

        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, boringVault, hex"");
        params[1] = abi.encode(token0, token1);
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

        bytes memory actions = abi.encodePacked(Actions.BURN_POSITION);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(positionId, amount0Min, amount1Min, hex"");

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
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(positionId, liquidity, amount0Max, amount1Max, hex"");
        params[1] = abi.encode(token0, token1);

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
            revert("Sad");
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
            revert("Sad");
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
