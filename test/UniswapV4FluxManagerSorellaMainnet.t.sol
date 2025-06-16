// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Auth, Authority} from "@solmate/src/auth/Auth.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {UniswapV4FluxManager, FluxManager} from "src/managers/UniswapV4FluxManager.sol";
import {BoringVault} from "src/BoringVault.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {RolesAuthority, Authority} from "@solmate/src/auth/authorities/RolesAuthority.sol";
import {StateLibrary, PoolId, IPoolManager} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {Test, stdStorage, StdStorage, stdError, console} from "@forge-std/Test.sol";
import {FullMath} from "@uni-v4-c/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uni-v3-p/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uni-v3-c/libraries/TickMath.sol";
import {ChainlinkDatum} from "src/datums/ChainlinkDatum.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {MockDatum} from "./mocks/MockDatum.sol";

contract UniswapV4FluxManagerTestSorellaMainnet is Test {
    using Address for address;
    using FixedPointMathLib for uint256;

    RolesAuthority internal rolesAuthority;
    BoringVault internal boringVault;
    ChainlinkDatum internal datum;
    UniswapV4FluxManager internal manager;
    address internal positionManager = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal universalRouter = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    ERC20 internal token0 = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ERC20 internal token1 = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address internal nativeWrapper = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IPoolManager internal poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    PoolId internal eth_usdc_pool_id = PoolId.wrap(0xF4CEA555F4656F4561ECD2A74EC2673331779220CD60686514983EDB16D027F3);
    address internal ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal hook = 0x0000000AA8c2Fb9b232F78D2B286dC2aE53BfAD4; // angstrom

    address internal payout = vm.addr(1);

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 22718611;

        _startFork(rpcKey, blockNumber);

        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));

        boringVault = new BoringVault{salt: "Test1"}(address(this), "Test1", "T1", 18);

        boringVault.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(
            1, address(boringVault), bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))), true
        );

        rolesAuthority.setUserRole(0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, 1, true);

        datum = new ChainlinkDatum(ETH_USD_ORACLE, 1 days, true);

        manager = new UniswapV4FluxManager(
            UniswapV4FluxManager.ConstructorArgs(
                address(this),
                address(boringVault),
                address(token0),
                address(token1),
                false,
                nativeWrapper,
                address(datum),
                0.995e4,
                1.005e4,
                positionManager,
                universalRouter,
                hook,
                uint24(0x800000), //dynamic fee
                10
            )
        );

        manager.setPayout(payout);

        uint256 price = 0.00037878787e18; // WETH per USDC in WETH decimals

        // Give required approvals.
        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](6);
        actions[0].kind = UniswapV4FluxManager.ActionKind.TOKEN0_APPROVE_PERMIT_2;
        actions[0].data = abi.encode(type(uint256).max);
        actions[1].kind = UniswapV4FluxManager.ActionKind.TOKEN0_PERMIT_2_APPROVE_POSITION_MANAGER;
        actions[1].data = abi.encode(type(uint160).max, type(uint48).max);
        actions[2].kind = UniswapV4FluxManager.ActionKind.TOKEN0_PERMIT_2_APPROVE_UNIVERSAL_ROUTER;
        actions[2].data = abi.encode(type(uint160).max, type(uint48).max);
        actions[3].kind = UniswapV4FluxManager.ActionKind.TOKEN1_APPROVE_PERMIT_2;
        actions[3].data = abi.encode(type(uint256).max);
        actions[4].kind = UniswapV4FluxManager.ActionKind.TOKEN1_PERMIT_2_APPROVE_POSITION_MANAGER;
        actions[4].data = abi.encode(type(uint160).max, type(uint48).max);
        actions[5].kind = UniswapV4FluxManager.ActionKind.TOKEN1_PERMIT_2_APPROVE_UNIVERSAL_ROUTER;
        actions[5].data = abi.encode(type(uint160).max, type(uint48).max);

        manager.rebalance(price, actions);

        manager.setPerformanceFee(0.2e4);
    }

    function testMinting() external {
        uint256 ethAmount = 1e16;
        uint256 usdcAmount = 2640e4;
        deal(nativeWrapper, address(boringVault), ethAmount);
        deal(address(token0), address(boringVault), usdcAmount);

        // (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);
        // console.log("=== Pool Slot0 Data ===");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        // console.log("tick:", tick);
        // console.log("protocolFee:", protocolFee);
        // console.log("lpFee:", lpFee);

        uint256 price = 0.00037878787e18;

        int24 tickLower = -887_220;
        int24 tickUpper = 887_220;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            usdcAmount,
            ethAmount
        );

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, usdcAmount, ethAmount, block.timestamp);
        manager.rebalance(price, actions);

        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(price);
        assertApproxEqRel(token1Balance, ethAmount, 0.02e18, "token0Balance should equate to original ethAmount");
        assertApproxEqRel(token0Balance, usdcAmount, 0.02e18, "token1Balance should equate to original usdcAmount");
    }

    function testBurning(uint256 ethAmount, uint256 usdcAmount) external {
        ethAmount = bound(ethAmount, 0.1e18, 1_000e18);
        usdcAmount = bound(usdcAmount, 100e6, 1_000_000e6);
        deal(nativeWrapper, address(boringVault), ethAmount);
        deal(address(token0), address(boringVault), usdcAmount);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);

        uint256 price = 0.00037878787e18;

        int24 tickLower = -887_220;
        int24 tickUpper = 887_220;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            usdcAmount,
            ethAmount
        );

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, usdcAmount, ethAmount, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.BURN;
        actions[0].data = abi.encode(manager.trackedPositions(0), 0, 0, block.timestamp);
        manager.rebalance(price, actions);

        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(price);
        assertApproxEqRel(token1Balance, ethAmount, 0.02e18, "token0Balance should equate to original ethAmount");
        assertApproxEqRel(token0Balance, usdcAmount, 0.02e18, "token1Balance should equate to original usdcAmount");
    }

    function testLiquidityManagement(uint256 ethAmount, uint256 usdcAmount) external {
        ethAmount = bound(ethAmount, 0.1e18, 1_000e18);
        usdcAmount = bound(usdcAmount, 100e6, 1_000_000e6);
        deal(nativeWrapper, address(boringVault), 2 * ethAmount);
        deal(address(token0), address(boringVault), 2 * usdcAmount);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);

        uint256 price = 0.00037878787e18;

        int24 tickLower = -887_220;
        int24 tickUpper = 887_220;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            usdcAmount,
            ethAmount
        );

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, usdcAmount, ethAmount, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.INCREASE_LIQUIDITY;
        actions[0].data = abi.encode(manager.trackedPositions(0), liquidity, usdcAmount, ethAmount, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.DECREASE_LIQUIDITY;
        actions[0].data = abi.encode(manager.trackedPositions(0), liquidity, 0, 0, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.COLLECT_FEES;
        actions[0].data = abi.encode(manager.trackedPositions(0), block.timestamp);
        manager.rebalance(price, actions);

        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(price);
        assertApproxEqRel(token1Balance, 2 * ethAmount, 0.02e18, "token0Balance should equate to original ethAmount");
        assertApproxEqRel(token0Balance, 2 * usdcAmount, 0.02e18, "token1Balance should equate to original usdcAmount");
    }

    function testLiquidityManagementMultiplePositions(uint256 ethAmount, uint256 usdcAmount) external {
        ethAmount = bound(ethAmount, 0.1e18, 1_000e18);
        usdcAmount = bound(usdcAmount, 100e6, 1_000_000e6);
        deal(nativeWrapper, address(boringVault), 4 * ethAmount);
        deal(address(token0), address(boringVault), 4 * usdcAmount);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);

        uint256 price = 0.00037878787e18;

        int24 tickLower = -887_220;
        int24 tickUpper = 887_220;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            usdcAmount,
            ethAmount
        );
        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            usdcAmount / 2,
            ethAmount / 2
        );
        uint128 liquidity2 = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(197130),
            0,
            ethAmount / 2
        );
        console.log("liquidity2", liquidity2);
        uint128 liquidity3 = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(197120),
            TickMath.getSqrtRatioAtTick(197130),
            usdcAmount / 2,
            ethAmount / 2
        );

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, usdcAmount, ethAmount, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.INCREASE_LIQUIDITY;
        actions[0].data = abi.encode(manager.trackedPositions(0), liquidity, usdcAmount, ethAmount, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity1, usdcAmount / 2, ethAmount / 2, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, 197130, liquidity2, 0, ethAmount / 2, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(197120, 197130, liquidity3, usdcAmount / 2, ethAmount / 2, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.DECREASE_LIQUIDITY;
        actions[0].data = abi.encode(manager.trackedPositions(0), liquidity, 0, 0, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.COLLECT_FEES;
        actions[0].data = abi.encode(manager.trackedPositions(0), block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.DECREASE_LIQUIDITY;
        actions[0].data = abi.encode(manager.trackedPositions(3), liquidity3 / 2, 0, 0, block.timestamp);
        manager.rebalance(price, actions);

        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(price);
        assertApproxEqRel(token1Balance, 4 * ethAmount, 0.02e18, "token0Balance should equate to original ethAmount");
        assertApproxEqRel(token0Balance, 4 * usdcAmount, 0.02e18, "token1Balance should equate to original usdcAmount");
    }

    function testSwapping() external {
        uint256 ethAmount = 1e18;
        uint256 usdcAmount = 10_000e6;
        deal(nativeWrapper, address(boringVault), ethAmount);
        deal(address(token1), address(boringVault), usdcAmount);

        uint256 price = 0.00037878787e18;

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](2);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_TOKEN0_FOR_TOKEN1_IN_POOL;
        actions[0].data = abi.encode(ethAmount / 2, 0, block.timestamp, bytes(""));
        actions[1].kind = UniswapV4FluxManager.ActionKind.SWAP_TOKEN1_FOR_TOKEN0_IN_POOL;
        actions[1].data = abi.encode(usdcAmount / 2, 0, block.timestamp, bytes(""));
        // reverts because Sorella hook locks the pool when the swap does not have the special unlock data provided by their off chain system
        // for the swap via their on chain executor
        vm.expectRevert(
            abi.encode("WrappedError(0x0000000AA8c2Fb9b232F78D2B286dC2aE53BfAD4, 0x575e24b4, 0x1e8107a0, 0xa9e35b2f)")
        );
        manager.rebalance(price, actions);
    }

    function testAggregatorSwapping() external {
        manager.setAggregator(address(this), true);
        uint256 ethAmount = 1e18;
        uint256 usdcAmount = 10_000e6;
        deal(nativeWrapper, address(boringVault), ethAmount);
        deal(address(token0), address(boringVault), usdcAmount);

        uint256 price = 0.00037878787e18; // ETH per USDC in ETH decimals
        uint256 usdPerEth = 2640e6; // USDC per ETH in USDC decimals
        UniswapV4FluxManager.Action[] memory actions;
        bytes memory swapData;

        uint256 expectedAmountOut = usdPerEth.mulDivDown(ethAmount / 2, 1e18);
        console.log("expectedAmountOut", expectedAmountOut);

        // Happy path
        swapData = abi.encodeWithSelector(this.swap.selector, token1, ethAmount / 2, token0, expectedAmountOut);
        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_WITH_AGGREGATOR;
        actions[0].data = abi.encode(address(this), ethAmount / 2, false, expectedAmountOut, swapData);
        manager.rebalance(price, actions);

        // Failure not meeting min amount out
        swapData = abi.encodeWithSelector(
            this.badSwapNotSpendingMeetingMinAmountOut.selector, token1, ethAmount / 2, token0, expectedAmountOut
        );
        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_WITH_AGGREGATOR;
        actions[0].data = abi.encode(address(this), ethAmount / 2, false, expectedAmountOut, swapData);
        vm.expectRevert(
            bytes(abi.encodeWithSelector(UniswapV4FluxManager.UniswapV4FluxManager__SwapAggregatorBadToken0.selector))
        );
        manager.rebalance(price, actions);

        // Failure minting shares during swap.
        swapData = abi.encodeWithSelector(
            this.badSwapNotSpendingMintingShares.selector, token1, ethAmount / 2, token0, expectedAmountOut
        );
        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_WITH_AGGREGATOR;
        actions[0].data = abi.encode(address(this), ethAmount / 2, false, expectedAmountOut, swapData);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(UniswapV4FluxManager.UniswapV4FluxManager__RebalanceChangedTotalSupply.selector)
            )
        );
        manager.rebalance(price, actions);

        // Failure not spending all approval
        swapData = abi.encodeWithSelector(this.badSwapNotSpendingAllApproval.selector, token0, usdcAmount, token1, 1);
        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_WITH_AGGREGATOR;
        actions[0].data = abi.encode(address(this), usdcAmount, true, 1, swapData);
        vm.expectRevert(
            bytes(abi.encodeWithSelector(UniswapV4FluxManager.UniswapV4FluxManager__SwapAggregatorBadToken0.selector))
        );
        manager.rebalance(price, actions);
    }

    // TODO test accounting with multiple different positions.

    function testGetRate() external view {
        uint256 exchangeRate = 0.00037878787e18;
        // BASE IN TOKEN 1 WETH
        uint256 rateIn0 = manager.getRate(exchangeRate, true);
        assertApproxEqRel(rateIn0, 2640e6, 0.0001e18, "Zero share rate should be 1/exRate in USDC decimals");
        uint256 rateIn1 = manager.getRate(exchangeRate, false);
        assertEq(rateIn1, 1e18, "Zero share rate should be 1 in WETH decimals");
    }

    // ========================================= HELPER FUNCTIONS =========================================

    receive() external payable {}

    function _startFork(string memory rpcKey, uint256 blockNumber) internal returns (uint256 forkId) {
        forkId = vm.createFork(vm.envString(rpcKey), blockNumber);
        vm.selectFork(forkId);
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

    // Mock Aggregator
    function swap(ERC20 tokenIn, uint256 amountIn, ERC20 tokenOut, uint256 minAmountOut) external payable {
        if (address(tokenIn) != address(0)) {
            // Transfer senders tokenIn in.
            tokenIn.transferFrom(msg.sender, address(this), amountIn);
        }

        if (address(tokenOut) == address(0)) {
            deal(msg.sender, msg.sender.balance + minAmountOut);
        } else {
            // Mint sender tokenOut
            deal(address(tokenOut), msg.sender, tokenOut.balanceOf(msg.sender) + minAmountOut);
        }
    }

    function badSwapNotSpendingAllApproval(ERC20 tokenIn, uint256 amountIn, ERC20 tokenOut, uint256 minAmountOut)
        external
        payable
    {
        if (address(tokenIn) != address(0)) {
            // Transfer senders tokenIn in.
            tokenIn.transferFrom(msg.sender, address(this), amountIn / 2);
        }

        if (address(tokenOut) == address(0)) {
            deal(msg.sender, msg.sender.balance + minAmountOut);
        } else {
            // Mint sender tokenOut
            deal(address(tokenOut), msg.sender, tokenOut.balanceOf(msg.sender) + minAmountOut);
        }
    }

    function badSwapNotSpendingMeetingMinAmountOut(
        ERC20 tokenIn,
        uint256 amountIn,
        ERC20 tokenOut,
        uint256 minAmountOut
    ) external payable {
        if (address(tokenIn) != address(0)) {
            // Transfer senders tokenIn in.
            tokenIn.transferFrom(msg.sender, address(this), amountIn);
        }

        if (address(tokenOut) == address(0)) {
            deal(msg.sender, msg.sender.balance + minAmountOut - 1);
        } else {
            // Mint sender tokenOut
            deal(address(tokenOut), msg.sender, tokenOut.balanceOf(msg.sender) + minAmountOut - 1);
        }
    }

    function badSwapNotSpendingMintingShares(ERC20 tokenIn, uint256 amountIn, ERC20 tokenOut, uint256 minAmountOut)
        external
        payable
    {
        if (address(tokenIn) != address(0)) {
            // Transfer senders tokenIn in.
            tokenIn.transferFrom(msg.sender, address(this), amountIn);
        }

        if (address(tokenOut) == address(0)) {
            deal(msg.sender, msg.sender.balance + minAmountOut);
        } else {
            // Mint sender tokenOut
            deal(address(tokenOut), msg.sender, tokenOut.balanceOf(msg.sender) + minAmountOut);
        }

        boringVault.enter(address(0), ERC20(address(0)), 0, address(this), 1);
    }
}
