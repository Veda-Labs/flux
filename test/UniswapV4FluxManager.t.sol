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

contract UniswapV4FluxManagerTest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;

    RolesAuthority internal rolesAuthority;
    BoringVault internal boringVault;
    ChainlinkDatum internal datum;
    UniswapV4FluxManager internal manager;
    address internal positionManager = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal universalRouter = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    ERC20 internal token0 = ERC20(address(0));
    ERC20 internal token1 = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal nativeWrapper = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IPoolManager internal poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    PoolId internal eth_usdc_pool_id = PoolId.wrap(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
    address internal ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal hook = address(0);

    address internal payout = vm.addr(1);

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 21918871;

        _startFork(rpcKey, blockNumber);

        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));

        boringVault = new BoringVault{salt: "Test1"}(address(this), "Test1", "T1", 18);

        boringVault.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(
            1, address(boringVault), bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))), true
        );

        rolesAuthority.setUserRole(0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, 1, true);

        datum = new ChainlinkDatum(ETH_USD_ORACLE, 1 days, false);

        manager = new UniswapV4FluxManager(
            address(this),
            address(boringVault),
            address(token0),
            address(token1),
            true,
            nativeWrapper,
            address(datum),
            0.995e4,
            1.005e4,
            positionManager,
            universalRouter,
            hook
        );

        manager.setPayout(payout);

        uint256 price = 2_652.626362e6;

        // Give required approvals.
        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](3);
        actions[0].kind = UniswapV4FluxManager.ActionKind.TOKEN1_APPROVE_PERMIT_2;
        actions[0].data = abi.encode(type(uint256).max);
        actions[1].kind = UniswapV4FluxManager.ActionKind.TOKEN1_PERMIT_2_APPROVE_POSITION_MANAGER;
        actions[1].data = abi.encode(type(uint160).max, type(uint48).max);
        actions[2].kind = UniswapV4FluxManager.ActionKind.TOKEN1_PERMIT_2_APPROVE_UNIVERSAL_ROUTER;
        actions[2].data = abi.encode(type(uint160).max, type(uint48).max);

        manager.rebalance(price, actions);

        manager.setPerformanceFee(0.2e4);
    }

    function testMinting() external {
        // uint256 ethAmount = 3e18;
        // uint256 usdcAmount = 10_000e6;
        uint256 ethAmount = 3384967315990850674;
        uint256 usdcAmount = 8979053538;
        deal(nativeWrapper, address(boringVault), ethAmount);
        deal(address(token1), address(boringVault), usdcAmount);

        // (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);
        // console.log("=== Pool Slot0 Data ===");
        // console.log("sqrtPriceX96:", sqrtPriceX96);
        // console.log("tick:", tick);
        // console.log("protocolFee:", protocolFee);
        // console.log("lpFee:", lpFee);

        uint256 price = 2_652.626362e6;

        int24 tickLower = -887_270;
        int24 tickUpper = 887_270;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            ethAmount,
            usdcAmount
        );

        // current tick for uniswap V3 pool 68456
        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, ethAmount, usdcAmount, block.timestamp);
        manager.rebalance(price, actions);

        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(price);
        assertApproxEqRel(token0Balance, ethAmount, 0.0001e18, "token0Balance should equate to original ethAmount");
        assertApproxEqRel(token1Balance, usdcAmount, 0.0001e18, "token1Balance should equate to original usdcAmount");
    }

    function testBurning(uint256 ethAmount, uint256 usdcAmount) external {
        ethAmount = bound(ethAmount, 0.1e18, 1_000e18);
        usdcAmount = bound(usdcAmount, 100e6, 1_000_000e6);
        deal(nativeWrapper, address(boringVault), ethAmount);
        deal(address(token1), address(boringVault), usdcAmount);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);

        uint256 price = 2_652.626362e6;

        int24 tickLower = -887_270;
        int24 tickUpper = 887_270;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            ethAmount,
            usdcAmount
        );

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, ethAmount, usdcAmount, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.BURN;
        actions[0].data = abi.encode(manager.trackedPositions(0), 0, 0, block.timestamp);
        manager.rebalance(price, actions);

        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(price);
        assertApproxEqRel(token0Balance, ethAmount, 0.0001e18, "token0Balance should equate to original ethAmount");
        assertApproxEqRel(token1Balance, usdcAmount, 0.0001e18, "token1Balance should equate to original usdcAmount");
    }

    function testLiquidityManagement(uint256 ethAmount, uint256 usdcAmount) external {
        ethAmount = bound(ethAmount, 0.1e18, 1_000e18);
        usdcAmount = bound(usdcAmount, 100e6, 1_000_000e6);
        deal(nativeWrapper, address(boringVault), 2 * ethAmount);
        deal(address(token1), address(boringVault), 2 * usdcAmount);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);

        uint256 price = 2_652.626362e6;

        int24 tickLower = -887_270;
        int24 tickUpper = 887_270;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            ethAmount,
            usdcAmount
        );

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, ethAmount, usdcAmount, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.INCREASE_LIQUIDITY;
        actions[0].data = abi.encode(manager.trackedPositions(0), liquidity, ethAmount, usdcAmount, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.DECREASE_LIQUIDITY;
        actions[0].data = abi.encode(manager.trackedPositions(0), liquidity / 2, 0, 0, block.timestamp);
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.COLLECT_FEES;
        actions[0].data = abi.encode(manager.trackedPositions(0), block.timestamp);
        manager.rebalance(price, actions);

        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(price);
        assertApproxEqRel(token0Balance, 2 * ethAmount, 0.0001e18, "token0Balance should equate to original ethAmount");
        assertApproxEqRel(
            token1Balance, 2 * usdcAmount, 0.0001e18, "token1Balance should equate to original usdcAmount"
        );
    }

    function testSwapping() external {
        uint256 ethAmount = 1e18;
        uint256 usdcAmount = 10_000e6;
        deal(nativeWrapper, address(boringVault), ethAmount);
        deal(address(token1), address(boringVault), usdcAmount);

        uint256 price = 2_652.626362e6;

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](2);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_TOKEN0_FOR_TOKEN1_IN_POOL;
        actions[0].data = abi.encode(ethAmount / 2, 0, block.timestamp, bytes(""));
        actions[1].kind = UniswapV4FluxManager.ActionKind.SWAP_TOKEN1_FOR_TOKEN0_IN_POOL;
        actions[1].data = abi.encode(usdcAmount / 2, 0, block.timestamp, bytes(""));
        manager.rebalance(price, actions);
    }

    function testAggregatorSwapping() external {
        manager.setAggregator(address(this), true);
        uint256 ethAmount = 1e18;
        uint256 usdcAmount = 10_000e6;
        deal(nativeWrapper, address(boringVault), ethAmount);
        deal(address(token1), address(boringVault), usdcAmount);

        uint256 price = 2_652.626362e6;
        UniswapV4FluxManager.Action[] memory actions;
        bytes memory swapData;

        uint256 expectedAmountOut = price.mulDivDown(ethAmount / 2, 1e18);

        // Happy path
        swapData = abi.encodeWithSelector(this.swap.selector, token0, ethAmount, token1, expectedAmountOut);
        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_WITH_AGGREGATOR;
        actions[0].data = abi.encode(ethAmount / 2, true, expectedAmountOut, swapData);
        manager.rebalance(price, actions);

        // Failure not meeting min amount out
        swapData = abi.encodeWithSelector(
            this.badSwapNotSpendingMeetingMinAmountOut.selector, token0, ethAmount, token1, expectedAmountOut
        );
        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_WITH_AGGREGATOR;
        actions[0].data = abi.encode(ethAmount / 2, true, expectedAmountOut, swapData);
        vm.expectRevert(
            bytes(abi.encodeWithSelector(UniswapV4FluxManager.UniswapV4FluxManager__SwapAggregatorBadToken1.selector))
        );
        manager.rebalance(price, actions);

        // Failure minting shares during swap.
        swapData = abi.encodeWithSelector(
            this.badSwapNotSpendingMintingShares.selector, token0, ethAmount, token1, expectedAmountOut
        );
        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_WITH_AGGREGATOR;
        actions[0].data = abi.encode(ethAmount / 2, true, expectedAmountOut, swapData);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(UniswapV4FluxManager.UniswapV4FluxManager__RebalanceChangedTotalSupply.selector)
            )
        );
        manager.rebalance(price, actions);

        // Failure not spending all approval
        swapData = abi.encodeWithSelector(this.badSwapNotSpendingAllApproval.selector, token1, usdcAmount, token0, 1);
        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_WITH_AGGREGATOR;
        actions[0].data = abi.encode(usdcAmount, false, 1, swapData);
        vm.expectRevert(
            bytes(abi.encodeWithSelector(UniswapV4FluxManager.UniswapV4FluxManager__SwapAggregatorBadToken1.selector))
        );
        manager.rebalance(price, actions);
    }

    // TODO test accounting with multiple different positions.

    function testGetRate() external view {
        uint256 exchangeRate = 2_652.626362e6;

        uint256 rateIn0 = manager.getRate(exchangeRate, true);
        assertEq(rateIn0, 1e18, "Zero share rate should be 1");
        uint256 rateIn1 = manager.getRate(exchangeRate, false);
        assertEq(rateIn1, exchangeRate, "Zero share rate should be exchange rate");
    }

    function testFees() external {
        // deposit huge amounts in order to be the primary LP and fee accruer
        uint256 ethAmount = 1e18 * 1_000_000;
        uint256 usdcAmount = 2_652.626362e6 * 1_000_000;
        deal(nativeWrapper, address(boringVault), 2 * ethAmount);
        deal(address(token1), address(boringVault), 2 * usdcAmount);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);

        uint256 price = 2_652.626362e6;

        int24 tickLower = -887_270;
        int24 tickUpper = 887_270;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            ethAmount,
            usdcAmount
        );

        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, ethAmount, usdcAmount, block.timestamp);
        manager.rebalance(price, actions);

        deal(address(token1), address(boringVault), 100e6);
        actions[0].kind = UniswapV4FluxManager.ActionKind.SWAP_TOKEN1_FOR_TOKEN0_IN_POOL;
        actions[0].data = abi.encode(100e6, 0, block.timestamp, bytes(""));
        manager.rebalance(price, actions);

        actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.COLLECT_FEES;
        actions[0].data = abi.encode(manager.trackedPositions(0), block.timestamp);
        manager.rebalance(price, actions);

        uint256 expectedFeeToVaultInUsdc = 5e4;

        manager.claimFees(false);

        assertApproxEqRel(token1.balanceOf(payout), expectedFeeToVaultInUsdc * manager.performanceFee() / 1e4, 1e16, "Claimed Fee should equal expected");
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
