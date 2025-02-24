// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {FluxManager} from "src/FluxManager.sol";
import {LiquidityAmounts} from "@uni-v3-p/libraries/LiquidityAmounts.sol";

contract UniswapV4FluxManager is FluxManager {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STRUCT                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct PositionData {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
    }

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

    constructor(address _owner, address _boringVault, address _token0, address _token1)
        FluxManager(_owner, _boringVault, _token0, _token1)
    {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     FLUX FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Refresh internal flux constants.
    /// @dev For Uniswap V4 this is token0 and token1 contract balances
    function _refreshInternalFluxAccounting() internal override {
        token0Balance = uint128(token0.balanceOf(address(boringVault)));
        token1Balance = uint128(token1.balanceOf(address(boringVault)));
    }

    /// @notice Refresh external flux constants(like Dex positions)
    function _refreshExternalFluxAccounting() internal override {}

    function _totalAssets(uint256 exchangeRate)
        internal
        view
        override
        returns (uint256 token0Assets, uint256 token1Assets)
    {
        return (0, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  STRATEGIST FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
}
