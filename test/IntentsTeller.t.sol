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
import {IntentsTeller, EIP712} from "src/tellers/IntentsTeller.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract IntentsTellerTest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;

    struct SigData {
        uint256 pK;
        address teller;
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
    address internal nativeWrapper = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    ERC20 internal token0 = ERC20(nativeWrapper);
    ERC20 internal token1 = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IPoolManager internal poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    PoolId internal eth_usdc_pool_id = PoolId.wrap(0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
    address internal ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address testUser0;
    uint256 testUser0Pk;

    address testUser1;
    uint256 testUser1Pk;

    address internal payout = vm.addr(1);

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 22222222;

        _startFork(rpcKey, blockNumber);

        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));

        boringVault = new BoringVault(address(this), "Test0", "T0", 6);

        boringVault.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(
            1, address(boringVault), bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))), true
        );

        rolesAuthority.setRoleCapability(
            2,
            address(boringVault),
            bytes4(keccak256(abi.encodePacked("enter(address,address,uint256,address,uint256)"))),
            true
        );
        rolesAuthority.setRoleCapability(
            2,
            address(boringVault),
            bytes4(keccak256(abi.encodePacked("exit(address,address,uint256,address,uint256)"))),
            true
        );

        datum = new ChainlinkDatum(ETH_USD_ORACLE, 1 days, false);

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
            address(0),
            500,
            10
        ));

        intentsTeller = new IntentsTeller(address(this), address(boringVault), address(manager), "Intents Teller", "2", 86400 * 7);

        intentsTeller.setAuthority(rolesAuthority);

        manager.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(
            2, address(manager), bytes4(keccak256(abi.encodePacked("refreshInternalFluxAccounting()"))), true
        );

        boringVault.setBeforeTransferHook(address(intentsTeller));

        intentsTeller.updateAssetData(token1, true, true, 0);
        intentsTeller.updateAssetData(token0, true, true, 0);

        // SET UP ROLES FOR TELLER ON VAULT
        rolesAuthority.setUserRole(address(intentsTeller), 2, true);


        // Make Signature Cancellation Public
        rolesAuthority.setPublicCapability(address(intentsTeller), IntentsTeller.cancelSignature.selector, true);

        // Set up test user.
        (testUser0, testUser0Pk) = makeAddrAndKey("testUser0");
        (testUser1, testUser1Pk) = makeAddrAndKey("testUser1");
    }

    function testDepositSimple() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            false
        );

        assertEq(boringVault.balanceOf(testUser0), amount);
    }

    function testWithdrawSimple() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        // manager.refreshInternalFluxAccounting(); -- this is now handled in deposit and withdraw

        // Withdraw using executor
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount / 2,
                minimumOut: 1,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        amount / 2,
                        1,
                        block.timestamp + 1 days
                    )
                )
            })
        );

        // Check that the withdraw was successful
        assertEq(boringVault.balanceOf(testUser0), amount / 2);
        assertEq(token1.balanceOf(testUser0), amount / 2);
    }

    function testCancelDepositSig() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        bytes memory depositSig = _generateSignature(
            SigData(
                testUser0Pk,
                address(intentsTeller),
                testUser0,
                address(token1),
                false,
                amount,
                0,
                block.timestamp + 1 days
            )
        );

        IntentsTeller.ActionData memory depositData = IntentsTeller.ActionData({
            isWithdrawal: false,
            user: testUser0,
            to: testUser0,
            asset: token1,
            amountIn: amount,
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: depositSig
        });

        // Give required approvals, but cancel the signature
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        intentsTeller.cancelSignature(depositData);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__DuplicateSignature.selector));
        intentsTeller.deposit(depositData, true);

        assertEq(boringVault.balanceOf(testUser0), 0);
    }

    function testPausing() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);
        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Pause Teller
        intentsTeller.pause();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__Paused.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            false
        );

        // Unpause Teller
        intentsTeller.unpause();
        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        // manager.refreshInternalFluxAccounting(); -- this is now handled in deposit and withdraw

        // Check that the deposit was successful
        assertEq(boringVault.balanceOf(testUser0), amount);

        // Pause Teller
        intentsTeller.pause();

        // Withdraw using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__Paused.selector));
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount / 2,
                minimumOut: 1,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        amount / 2,
                        1,
                        block.timestamp + 1 days
                    )
                )
            })
        );

        // Unpause Teller
        intentsTeller.unpause();

        // Withdraw using executor
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount / 2,
                minimumOut: 1,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        amount / 2,
                        1,
                        block.timestamp + 1 days
                    )
                )
            })
        );
        // Check that the withdraw was successful
        assertEq(boringVault.balanceOf(testUser0), amount / 2);
        assertEq(token1.balanceOf(testUser0), amount / 2);
    }

    function testTransferDenials() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);
        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deny list user
        intentsTeller.denyAll(testUser0);

        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            false
        );
        vm.prank(testUser0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentsTeller.IntentsTeller__TransferDenied.selector, testUser0, address(this), testUser0
            )
        );
        boringVault.transfer(address(this), amount);

        intentsTeller.allowTo(testUser0);

        vm.prank(testUser0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentsTeller.IntentsTeller__TransferDenied.selector, testUser0, address(this), testUser0
            )
        );
        boringVault.transfer(address(this), amount);

        intentsTeller.allowFrom(testUser0);
        vm.prank(testUser0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentsTeller.IntentsTeller__TransferDenied.selector, testUser0, address(this), testUser0
            )
        );
        boringVault.transfer(address(this), amount);

        intentsTeller.allowOperator(testUser0);
        vm.prank(testUser0);
        boringVault.transfer(address(this), 1e5);

        intentsTeller.setPermissionedTransfers(true);
        vm.prank(testUser0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentsTeller.IntentsTeller__TransferDenied.selector, testUser0, address(this), testUser0
            )
        );
        boringVault.transfer(address(this), 1e5);

        intentsTeller.allowPermissionedOperator(testUser0);
        vm.prank(testUser0);
        boringVault.transfer(address(this), 2e8);

        intentsTeller.denyAll(testUser0);
        vm.prank(testUser0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentsTeller.IntentsTeller__TransferDenied.selector, testUser0, address(this), testUser0
            )
        );
        boringVault.transfer(address(this), 2e8);

        intentsTeller.allowAll(testUser0);
        vm.prank(testUser0);
        boringVault.transfer(address(this), 1e8);

        intentsTeller.denyPermissionedOperator(testUser0);
        vm.prank(testUser0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentsTeller.IntentsTeller__TransferDenied.selector, testUser0, address(this), testUser0
            )
        );
        boringVault.transfer(address(this), 3e7);

    }

    function testShareLockPeriod() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);
        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Set the share lock period above max limit
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__ShareLockPeriodTooLong.selector));
        intentsTeller.setShareLockPeriod(8 days);

        // Set the share lock period to 3 days
        intentsTeller.setShareLockPeriod(3 days);

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        assertEq(boringVault.balanceOf(testUser0), amount);

        // Check that share lock is enforced, and properly expires
        vm.startPrank(testUser0);
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__SharesAreLocked.selector));
        boringVault.transfer(address(this), amount);

        vm.warp(block.timestamp + 3 days + 1);
        boringVault.transfer(address(this), amount);
    }

    function testRefundDeposit() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        intentsTeller.setShareLockPeriod(3 days);

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        assertEq(boringVault.balanceOf(testUser0), amount);

        // Refund deposit
        intentsTeller.refundDeposit(1, testUser0, address(token1), amount, amount, block.timestamp, 3 days);

        assertEq(boringVault.balanceOf(testUser0), 0);
        assertEq(token1.balanceOf(testUser0), amount);
    }

    function testDepositWithdrawToken0NativeWrapper() external {
        uint256 amount = 1e18;
        // Fund test user with tokens.
        deal(address(token0), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token0.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token0,
                amountIn: amount,
                minimumOut: 1,
                rate: 1589835727, // USDC per ETH
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token0),
                        false,
                        amount,
                        1,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        assertEq(boringVault.balanceOf(testUser0), 1589835727);
        assertEq(token0.balanceOf(testUser0), 0);

        // Now Withdraw
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token0,
                amountIn: 1589835727,
                minimumOut: 1,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token0),
                        true,
                        1589835727,
                        1,
                        block.timestamp + 1 days
                    )
                )
            })
        );

        assertEq(boringVault.balanceOf(testUser0), 0);
        assertApproxEqRel(token0.balanceOf(testUser0), amount, 1e12); //0.0001% error tolerance
    }

    function testMultipleAssetsDepositWithdraw() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        assertEq(boringVault.balanceOf(testUser0), amount);


        uint256 amount1 = 1e18;
        // Now Deposit token0 with user 1
        deal(address(token0), testUser1, amount1);
        vm.startPrank(address(testUser1));
        token0.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser1,
                to: testUser1,
                asset: token0,
                amountIn: amount1,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser1Pk,
                        address(intentsTeller),
                        testUser1,
                        address(token0),
                        false,
                        amount1,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        assertEq(boringVault.balanceOf(testUser1), 1589835727);
        assertEq(token0.balanceOf(testUser1), 0);

        // Now Withdraw token1 with user 0
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 1,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        amount,
                        1,
                        block.timestamp + 1 days
                    )
                )
            })
        );
        assertEq(boringVault.balanceOf(testUser0), 0);
        assertEq(token1.balanceOf(testUser0), amount);

        // Now Withdraw token0 with user 1
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser1,
                to: testUser1,
                asset: token0,
                amountIn: 1589835727,
                minimumOut: 1,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser1Pk,
                        address(intentsTeller),
                        testUser1,
                        address(token0),
                        true,
                        1589835727,
                        1,
                        block.timestamp + 1 days
                    )
                )
            })
        );
        assertEq(boringVault.balanceOf(testUser1), 0);
        assertApproxEqRel(token0.balanceOf(testUser1), amount1, 1e12); //0.0001% error tolerance

    }

    function testBulkActions() external {
        // generate signature for user 0 to deposit 1e10 USDC to user 1
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Generate signature for user 0 to deposit 1e10 USDC to user 1
        bytes memory depositSig = _generateSignature(
            SigData(
                testUser0Pk,
                address(intentsTeller),
                testUser1,
                address(token1),
                false,
                amount,
                0,
                block.timestamp + 1 days
            )
        );

        // Generate signature for user 1 to withdraw 5e9 USDC to user 0
        bytes memory withdrawSig = _generateSignature(
            SigData(
                testUser1Pk,
                address(intentsTeller),
                testUser0,
                address(token1),
                true,
                amount / 2,
                0,
                block.timestamp + 1 days
            )
        );

        // Generate Array of actions
        IntentsTeller.ActionData[] memory actions = new IntentsTeller.ActionData[](2);
        actions[0] = IntentsTeller.ActionData({
            isWithdrawal: false,
            user: testUser0,
            to: testUser1,
            asset: token1,
            amountIn: amount,
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: depositSig
        });
        actions[1] = IntentsTeller.ActionData({
            isWithdrawal: true,
            user: testUser1,
            to: testUser0,
            asset: token1,
            amountIn: amount / 2,
            minimumOut: 0,
            rate: 1589835727,
            deadline: block.timestamp + 1 days,
            sig: withdrawSig
        });

        bool[] memory enforceShareLock = new bool[](2);
        enforceShareLock[0] = false;
        enforceShareLock[1] = false;

        // Use bulk actions to deposit and withdraw
        intentsTeller.bulkActions(actions, enforceShareLock);

        // Check that the actions were successful
        assertEq(boringVault.balanceOf(testUser1), amount / 2);
        assertEq(boringVault.balanceOf(testUser0), 0);
        assertEq(token1.balanceOf(testUser0), amount / 2);
        assertEq(token1.balanceOf(testUser1), 0);
    }

    // ========================================= TESTS FOR FAILURES =========================================

    function testDepositFailsActionMismatch() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__InvalidSignature.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: true, // This causes the expected failure
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );
    }

    function testDepositFailsSigActionMismatch() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__InvalidSignature.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true, // This causes the expected failure
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );
    }

    function testDepositFailsAmountMismatch() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__InvalidSignature.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount / 2, // This causes the expected failure
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );
    }

    function testDepositFailsFromOtherUser() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__InvalidSignature.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser1, // This causes the failure
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );
    }

    function testDepositFailsToDifferentUser() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__InvalidSignature.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser1, // This causes the expected failure
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );
    }

    function testDepositFailsDeadlinePassed() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__SignatureExpired.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp - 1, // This causes the expected failure
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp - 1
                    )
                )
            }),
            true
        );
    }

    function testDepositFailsDeadlineTooFarInFuture() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__DeadlineOutsideMaxPeriod.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 7 days + 1, // This causes the expected failure
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 7 days + 1
                    )
                )
            }),
            true
        );
    }

    function testDepositFailsWhenMinOutNotMet() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__MinimumMintNotMet.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 1e10 + 1, // This causes the expected failure
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        1e10 + 1,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );
    }

    function testWithdrawFailsWhenMinOutNotMet() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        // Withdraw using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__MinimumAssetsNotMet.selector));
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount / 2,
                minimumOut: 1e10 + 1, // This causes the expected failure
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        amount / 2,
                        1e10 + 1,
                        block.timestamp + 1 days
                    )
                )
            })
        );
    }

    function testDepositFailsWithBadRate() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor (rate too high)
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkDatum.ChainlinkDatum__InvalidExchangeRate.selector, 159571347400, 157983572700, 159571347300
            )
        );
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 1e10,
                rate: 1595713474, // This causes the expected failure (1579835727 to 1595713473 are valid rates)
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        1e10,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        // Deposit using executor (rate too low)
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkDatum.ChainlinkDatum__InvalidExchangeRate.selector, 157983572600, 157983572700, 159571347300
            )
        );
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 1e10,
                rate: 1579835726, // This causes the expected failure (1579835727 to 1595713473 are valid rates)
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        1e10,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );
    }

    function testWithdrawFailsWithBadRate() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor with good rate
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 1e10,
                rate: 1593713474, // This causes the expected failure (1579835727 to 1595713473 are valid rates)
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        1e10,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        // Withdraw using executor (rate too high)
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkDatum.ChainlinkDatum__InvalidExchangeRate.selector, 159571347400, 157983572700, 159571347300
            )
        );
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 1e10,
                rate: 1595713474, // This causes the expected failure (1579835727 to 1595713473 are valid rates)
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        amount,
                        1e10,
                        block.timestamp + 1 days
                    )
                )
            })
        );

        // Withdraw using executor (rate too low)
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkDatum.ChainlinkDatum__InvalidExchangeRate.selector, 157983572600, 157983572700, 159571347300
            )
        );
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 1e10,
                rate: 1579835726, // This causes the expected failure (1579835727 to 1595713473 are valid rates)
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        amount,
                        1e10,
                        block.timestamp + 1 days
                    )
                )
            })
        );
    }

    function testDepositFailsZeroAssets() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__ZeroAssets.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: 0, // This causes the expected failure
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        0,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            false
        );
    }

    function testWithdrawFailsZeroShares() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        // Attempt Withdraw using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__ZeroShares.selector));
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: true,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: 0, // This causes the expected failure
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        true,
                        0,
                        0,
                        block.timestamp + 1 days
                    )
                )
            })
        );
        assertEq(boringVault.balanceOf(testUser0), amount);
    }

    function testDepositsFailWhenAssetNotSupported() external {
        uint256 amount = 1e10;

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__AssetNotSupported.selector));
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7), // This causes the expected failure
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        0xdAC17F958D2ee523a2206206994597C13D831ec7,
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            false
        );
    }

    function testWithdrawsFailWhenAssetNotSupported() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            false
        );

        // Deposit using executor
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__AssetNotSupported.selector));
        intentsTeller.withdraw(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: ERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7), // This causes the expected failure
                amountIn: amount,
                minimumOut: 1,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        0xdAC17F958D2ee523a2206206994597C13D831ec7,
                        false,
                        amount,
                        1,
                        block.timestamp + 1 days
                    )
                )
            })
        );
    }

    function testRefundDepositFails() external {
        uint256 amount = 1e10;
        // Fund test user with tokens.
        deal(address(token1), testUser0, amount);

        // Give required approvals.
        vm.startPrank(address(testUser0));
        token1.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        intentsTeller.setShareLockPeriod(3 days);

        // Deposit using executor
        intentsTeller.deposit(
            IntentsTeller.ActionData({
                isWithdrawal: false,
                user: testUser0,
                to: testUser0,
                asset: token1,
                amountIn: amount,
                minimumOut: 0,
                rate: 1589835727,
                deadline: block.timestamp + 1 days,
                sig: _generateSignature(
                    SigData(
                        testUser0Pk,
                        address(intentsTeller),
                        testUser0,
                        address(token1),
                        false,
                        amount,
                        0,
                        block.timestamp + 1 days
                    )
                )
            }),
            true
        );

        assertEq(boringVault.balanceOf(testUser0), amount);

        // Refund deposit with bad receiver
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__BadDepositHash.selector));
        intentsTeller.refundDeposit(1, testUser1, address(token1), amount, amount, block.timestamp, 3 days);

        assertEq(boringVault.balanceOf(testUser0), amount);
        uint256 depositTimestamp = block.timestamp;
        vm.warp(block.timestamp + 3 days + 1);
        // Refund deposit after unlock
        vm.expectRevert(abi.encodeWithSelector(IntentsTeller.IntentsTeller__SharesAreUnLocked.selector));
        intentsTeller.refundDeposit(1, testUser0, address(token1), amount, amount, depositTimestamp, 3 days);
        assertEq(boringVault.balanceOf(testUser0), amount);
    }

    // ========================================= HELPER FUNCTIONS =========================================
    function _startFork(string memory rpcKey, uint256 blockNumber) internal returns (uint256 forkId) {
        forkId = vm.createFork(vm.envString(rpcKey), blockNumber);
        vm.selectFork(forkId);
    }

    function _generateSignature(SigData memory sigData) internal view returns (bytes memory sig) {
        bytes32 TYPE_HASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        // Get the domain separator from the contract
        bytes32 domainSeparator = keccak256(abi.encode(TYPE_HASH, keccak256(bytes("Intents Teller")), keccak256(bytes("2")), block.chainid, address(intentsTeller)));
        
        bytes32 hash = keccak256(
            abi.encode(
                sigData.teller,
                sigData.to,
                sigData.asset,
                sigData.isWithdrawal,
                sigData.amountIn,
                sigData.minimumOut,
                sigData.deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sigData.pK, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
    //     return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    // }

}
