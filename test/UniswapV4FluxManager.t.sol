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

contract BoringDroneTest is Test {
    using Address for address;

    RolesAuthority internal rolesAuthority;
    BoringVault internal boringVault;
    ChainlinkDatum internal datum;
    UniswapV4FluxManager internal manager;
    address internal positionManager = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    ERC20 internal token0 = ERC20(address(0));
    ERC20 internal token1 = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal nativeWrapper = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IPoolManager internal poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    PoolId internal eth_usdc_pool_id = PoolId.wrap(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
    address internal ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address internal payout = vm.addr(1);

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 21918871;

        _startFork(rpcKey, blockNumber);

        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));

        boringVault = new BoringVault(address(this), "Test", "T", 18);

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
            positionManager
        );

        manager.setPayout(payout);
    }

    function testMinting() external {
        // uint256 ethAmount = 3e18;
        // uint256 usdcAmount = 10_000e6;
        uint256 ethAmount = 3384967315990850674;
        uint256 usdcAmount = 8979053538;
        deal(address(boringVault), ethAmount);
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

        console.log("Liquidity minting", liquidity);

        // current tick for uniswap V3 pool 68456
        UniswapV4FluxManager.Action[] memory actions = new UniswapV4FluxManager.Action[](1);
        actions[0].kind = UniswapV4FluxManager.ActionKind.MINT;
        actions[0].data = abi.encode(tickLower, tickUpper, liquidity, ethAmount, usdcAmount, block.timestamp);
        manager.rebalance(price, actions);

        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(price);
        assertApproxEqRel(token0Balance, ethAmount, 0.0001e18, "token0Balance should equate to original ethAmount");
        assertApproxEqRel(token1Balance, usdcAmount, 0.0001e18, "token1Balance should equate to original usdcAmount");

        uint256 totalAssetsInToken0 = manager.totalAssets(price, true);
        uint256 totalAssetsInToken1 = manager.totalAssets(price, false);

        console.log("Total Assets in Token0: ", totalAssetsInToken0);
        console.log("Total Assets in Token1: ", totalAssetsInToken1);

        console.log("ETH Balance: ", address(boringVault).balance);
        console.log("USDC Balance: ", token1.balanceOf(address(boringVault)));
    }

    function testGetRate() external {
        uint256 exchangeRate = 2_652.626362e6;

        uint256 rateIn0 = manager.getRate(exchangeRate, true);
        assertEq(rateIn0, 1e18, "Zero share rate should be 1");
        uint256 rateIn1 = manager.getRate(exchangeRate, false);
        assertEq(rateIn1, exchangeRate, "Zero share rate should be exchange rate");
    }

    function testPerformanceReviewInToken0() external {
        // Mint some shares so we can reviewPerformance
        boringVault.enter(address(0), ERC20(address(0)), 0, address(this), 1e18);
        uint256 ethAmount = 0;
        uint256 usdcAmount = 50_000e6;
        deal(address(boringVault), ethAmount);
        deal(address(token1), address(boringVault), usdcAmount);

        uint256 exchangeRate = 2_652.626362e6;

        manager.switchPerformanceMetric(FluxManager.PerformanceMetric.TOKEN0, true);

        manager.reviewPerformance();

        assertEq(manager.pendingFee(), 0, "Pending Fee should be zero");

        deal(address(token1), address(boringVault), 2 * usdcAmount);

        manager.reviewPerformance();

        uint256 expectedFeeInUsdc = 10_000e6;

        manager.claimFees(false);

        assertApproxEqAbs(token1.balanceOf(payout), expectedFeeInUsdc, 1, "Claimed Fee should equal expected");
    }

    function testPerformanceReviewInToken1() external {
        // Mint some shares so we can reviewPerformance
        boringVault.enter(address(0), ERC20(address(0)), 0, address(this), 1e18);
        uint256 ethAmount = 0;
        uint256 usdcAmount = 50_000e6;
        deal(address(boringVault), ethAmount);
        deal(address(token1), address(boringVault), usdcAmount);

        uint256 exchangeRate = 2_652.626362e6;

        manager.switchPerformanceMetric(FluxManager.PerformanceMetric.TOKEN1, true);

        manager.reviewPerformance();

        assertEq(manager.pendingFee(), 0, "Pending Fee should be zero");

        deal(address(token1), address(boringVault), 100_000e6);

        manager.reviewPerformance();

        uint256 expectedFeeInUsdc = 10_000e6;

        manager.claimFees(false);

        assertEq(token1.balanceOf(payout), expectedFeeInUsdc, "Claimed Fee should equal expected");
    }

    function testPerformanceReviewInLiquidity(int24 tickLower, int24 tickUpper) external {
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, eth_usdc_pool_id);

        tickLower = int24(bound(tickLower, -887_270, tick - 1));
        tickUpper = int24(bound(tickUpper, tick + 1, 887_269));
        if (tickLower == tickUpper) {
            tickUpper++;
        }
        if (tickLower > tickUpper) {
            (tickLower, tickUpper) = (tickUpper, tickLower);
        }
        // Mint some shares so we can reviewPerformance
        boringVault.enter(address(0), ERC20(address(0)), 0, address(this), 1e18);
        uint256 ethAmount = 0;
        uint256 usdcAmount = 50_000e6;
        deal(address(boringVault), ethAmount);
        deal(address(token1), address(boringVault), usdcAmount);

        uint256 exchangeRate = 2_652.626362e6;

        console.log("tickLower: ", tickLower);
        console.log("tickUpper: ", tickUpper);
        manager.setReferenceTicks(tickLower, tickUpper, true);
        manager.switchPerformanceMetric(FluxManager.PerformanceMetric.LIQUIDITY, true);

        manager.reviewPerformance();

        assertEq(manager.pendingFee(), 0, "Pending Fee should be zero");

        deal(address(token1), address(boringVault), 100_000e6);

        manager.reviewPerformance();

        uint256 expectedFeeInUsdc = 10_000e6;

        manager.claimFees(false);

        assertApproxEqRel(token1.balanceOf(payout), expectedFeeInUsdc, 0.0001e18, "Claimed Fee should equal expected");
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
}
