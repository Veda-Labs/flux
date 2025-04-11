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
import {IntentsTeller, MessageHashUtils} from "src/tellers/IntentsTeller.sol";

contract IntentsTellerTest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;

    struct SigData {
        uint256 pK;
        address teller;
        address executor;
        address to;
        address asset;
        bool isWithdrawal;
        uint256 amountIn;
        uint256 minimumOut;
        uint256 deadline;
    }

    RolesAuthority internal rolesAuthority;
    BoringVault internal boringVault;
    ChainlinkDatum internal datum;
    UniswapV4FluxManager internal manager;
    IntentsTeller internal intentsTeller;
    address internal positionManager = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal universalRouter = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    ERC20 internal token0 = ERC20(address(0));
    ERC20 internal token1 = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal nativeWrapper = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IPoolManager internal poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    PoolId internal eth_usdc_pool_id = PoolId.wrap(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
    address internal ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address testUser;
    uint256 testUserPk;

    address internal payout = vm.addr(1);

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 22222222;

        _startFork(rpcKey, blockNumber);

        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));

        boringVault = new BoringVault(address(this), "Test0", "T0", 18);

        boringVault.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(
            1, address(boringVault), bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))), true
        );

        rolesAuthority.setRoleCapability(
            2, address(boringVault), bytes4(keccak256(abi.encodePacked("enter(address,address,uint256,address,uint256)"))), true
        );
        rolesAuthority.setRoleCapability(
            2, address(boringVault), bytes4(keccak256(abi.encodePacked("exit(address,address,uint256,address,uint256)"))), true
        );

        //rolesAuthority.setUserRole(0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, 1, true);  // TODO: check this

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
            universalRouter
        );

        intentsTeller = new IntentsTeller(
            address(this),
            address(boringVault),
            address(manager),
            86400 * 7
        );

        intentsTeller.setAuthority(rolesAuthority);

        // GIVE ROLE 1 ALL SOLVER PERMS
        // rolesAuthority.setRoleCapability(
        //     1, address(intentsTeller), bytes4(keccak256(abi.encodePacked("deposit((uint256,address,address,address,address,bool,uint256,uin256,uint256))"))), true
        // );
        // rolesAuthority.setRoleCapability(
        //     1, address(intentsTeller), bytes4(keccak256(abi.encodePacked("bulkWithdraw((uint256,address,address,address,address,bool,uint256,uin256,uint256))"))), true
        // );

        intentsTeller.updateAssetData(token1, true, true, 0);

        // SET UP ROLES FOR TELLER ON VAULT
        rolesAuthority.setUserRole(
            address(intentsTeller),
            2,
            true
        );

        // SET UP ROLES FOR SOLVER ON TELLER
        // rolesAuthority.setUserRole(
        //     address(this),
        //     1,
        //     true
        // );

        // Set up test user.
        (testUser, testUserPk) = makeAddrAndKey("testUser0");

    }

    function testDepositSimple() external {
        uint256 amount = 1e18;
        // Fund test user with tokens.
        deal(address(token1), testUser, amount);

        // Give required approvals.
        vm.startPrank(address(testUser));
        token1.approve(address(boringVault), type(uint256).max);
        token1.approve(address(intentsTeller), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(IntentsTeller.ActionData({
            isWithdrawal: false,
            user: testUser,
            to: testUser,
            asset: token1,
            amountIn: amount,
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: _generateSignature(SigData(
                testUserPk,
                address(intentsTeller),
                address(this),
                testUser,
                address(token1),
                false,
                amount,
                0,
                block.timestamp + 1 days
            ))
        }));
        vm.stopPrank();

        assertEq(boringVault.balanceOf(testUser), amount);
    }

    function testWithdrawSimple() external {
        uint256 amount = 1e18;
        // Fund test user with tokens.
        deal(address(token1), testUser, amount);

        // Give required approvals.
        vm.startPrank(address(testUser));
        token1.approve(address(boringVault), type(uint256).max);
        token1.approve(address(intentsTeller), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(IntentsTeller.ActionData({
            isWithdrawal: false,
            user: testUser,
            to: testUser,
            asset: token1,
            amountIn: amount,
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: _generateSignature(SigData(
                testUserPk,
                address(intentsTeller),
                address(this),
                testUser,
                address(token1),
                false,
                amount,
                0,
                block.timestamp + 1 days
            ))
        }));
        vm.stopPrank();

        // Withdraw using executor
        intentsTeller.bulkWithdraw(IntentsTeller.ActionData({
            isWithdrawal: true,
            user: testUser,
            to: testUser,
            asset: token1,
            amountIn: amount / 2,
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: _generateSignature(SigData(
                testUserPk,
                address(intentsTeller),
                address(this),
                testUser,
                address(token1),
                true,
                amount / 2,
                0,
                block.timestamp + 1 days
            ))
        }));
        vm.stopPrank();

        assertEq(boringVault.balanceOf(testUser), amount / 2);
    }

    // ========================================= TESTS FOR FAILURES =========================================

    function testDepositFailsActionMismatch() external {
        uint256 amount = 1e18;
        // Fund test user with tokens.
        deal(address(token1), testUser, amount);

        // Give required approvals.
        vm.startPrank(address(testUser));
        token1.approve(address(boringVault), type(uint256).max);
        token1.approve(address(intentsTeller), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(
            abi.encodeWithSelector(IntentsTeller.IntentsTeller__ActionMismatch.selector)
        );
        intentsTeller.deposit(IntentsTeller.ActionData({
            isWithdrawal: true, // This causes the expected failure
            user: testUser,
            to: testUser,
            asset: token1,
            amountIn: amount,
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: _generateSignature(SigData(
                testUserPk,
                address(intentsTeller),
                address(this),
                testUser,
                address(token1),
                false,
                amount,
                0,
                block.timestamp + 1 days
            ))
        }));
        vm.stopPrank();
    }

    function testDepositFailsSigActionMismatch() external {
        uint256 amount = 1e18;
        // Fund test user with tokens.
        deal(address(token1), testUser, amount);

        // Give required approvals.
        vm.startPrank(address(testUser));
        token1.approve(address(boringVault), type(uint256).max);
        token1.approve(address(intentsTeller), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(
            abi.encodeWithSelector(IntentsTeller.IntentsTeller__InvalidSignature.selector)
        );
        intentsTeller.deposit(IntentsTeller.ActionData({
            isWithdrawal: false,
            user: testUser,
            to: testUser,
            asset: token1,
            amountIn: amount,
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: _generateSignature(SigData(
                testUserPk,
                address(intentsTeller),
                address(this),
                testUser,
                address(token1),
                true, // This causes the expected failure
                amount,
                0,
                block.timestamp + 1 days
            ))
        }));
        vm.stopPrank();
    }

    function testDepositFailsAmountMismatch() external {
        uint256 amount = 1e18;
        // Fund test user with tokens.
        deal(address(token1), testUser, amount);

        // Give required approvals.
        vm.startPrank(address(testUser));
        token1.approve(address(boringVault), type(uint256).max);
        token1.approve(address(intentsTeller), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(
            abi.encodeWithSelector(IntentsTeller.IntentsTeller__InvalidSignature.selector)
        );
        intentsTeller.deposit(IntentsTeller.ActionData({
            isWithdrawal: false,
            user: testUser,
            to: testUser,
            asset: token1,
            amountIn: amount / 2 ,  // This causes the expected failure
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: _generateSignature(SigData(
                testUserPk,
                address(intentsTeller),
                address(this),
                testUser,
                address(token1),
                true,
                amount,
                0,
                block.timestamp + 1 days
            ))
        }));
        vm.stopPrank();
    }

    // ========================================= HELPER FUNCTIONS =========================================
    function _startFork(string memory rpcKey, uint256 blockNumber) internal returns (uint256 forkId) {
        forkId = vm.createFork(vm.envString(rpcKey), blockNumber);
        vm.selectFork(forkId);
    }

    function _generateSignature(
        SigData memory sigData
    ) internal pure returns (bytes memory sig) {
        bytes32 hash = keccak256(abi.encodePacked(sigData.teller, sigData.executor, sigData.to, sigData.asset, sigData.isWithdrawal, sigData.amountIn, sigData.minimumOut, sigData.deadline));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sigData.pK, digest);
        sig = abi.encodePacked(r, s, v);
    }

}