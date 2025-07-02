// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Auth, Authority} from "@solmate/src/auth/Auth.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {UniswapV4FluxManager, FluxManager} from "src/managers/UniswapV4FluxManager.sol";
import {IntentsTeller} from "src/tellers/IntentsTeller.sol";
import {BoringVault} from "src/BoringVault.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {RolesAuthority, Authority} from "@solmate/src/auth/authorities/RolesAuthority.sol";
import {ChainlinkDatum} from "src/datums/ChainlinkDatum.sol";
import {Script} from "@forge-std/Script.sol";
import {PoolId, IPoolManager} from "lib/v4-core/src/libraries/StateLibrary.sol";

contract DeploySorellaVaultSimple is Script {
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
    bool internal baseIn0Or1 = false;

    address internal scriptOwner;
    address internal owner;
    address internal payout;
    address internal strategist;

    uint24 internal poolFee = uint24(0x800000);
    int24 internal tickSpacing = int24(10);

    IntentsTeller internal teller;

    function run() public {
        vm.startBroadcast();
        /// DEPLOY CONTRACTS

        // ownership for test deployment set to scriptOwner
        scriptOwner = msg.sender;

        // deploy roles authority with scriptOwner as owner
        rolesAuthority = new RolesAuthority(scriptOwner, Authority(address(0)));

        // deploy boring vault with scriptOwner as owner
        boringVault = new BoringVault(scriptOwner, "Test1", "T1", 18);

        // deploy datum
        datum = new ChainlinkDatum(ETH_USD_ORACLE, 1 days, true);

        // deploy manager with scriptOwner as owner
        manager = new UniswapV4FluxManager(
            UniswapV4FluxManager.ConstructorArgs({
                owner: address(scriptOwner),
                boringVault: address(boringVault),
                token0: address(token0),
                token1: address(token1),
                baseIn0Or1: baseIn0Or1,
                nativeWrapper: nativeWrapper,
                datum: address(datum),
                datumLowerBound: 0.995e4,
                datumUpperBound: 1.005e4,
                positionManager: positionManager,
                universalRouter: universalRouter,
                hook: hook,
                poolFee: poolFee,
                tickSpacing: tickSpacing
            })
        );

        // deploy teller with scriptOwner as owner
        teller = new IntentsTeller(
            scriptOwner,
            address(boringVault),
            address(manager),
            "TestTeller1",
            "0.1",
            7 days
        );

        // set roles authority as authority for boring vault
        boringVault.setAuthority(rolesAuthority);

        // set roles authority as authority for manager
        manager.setAuthority(rolesAuthority);

        // set roles authority as authority for teller
        teller.setAuthority(rolesAuthority);

        // create role capability for managing the vault
        rolesAuthority.setRoleCapability(
            1, address(boringVault), bytes4(keccak256(abi.encodePacked("manage(address,bytes,uint256)"))), true
        );

        // grant the manager the role to manage the vault
        rolesAuthority.setUserRole(address(manager), 1, true);

        // create a role for calling rebalance on the manager
        rolesAuthority.setRoleCapability(
            7, address(manager), bytes4(keccak256(abi.encodePacked("rebalance(uint256,(uint8,bytes)[])"))), true
        );

        // grant the strategist address the role to rebalance
        rolesAuthority.setUserRole(strategist, 7, true);

        // set payout address
        manager.setPayout(strategist);

        // set performance fee
        manager.setPerformanceFee(0.2e4);

        
        // SET UP TELLER

        // add assets to teller
        teller.updateAssetData(token1, true, true, 0);
        teller.updateAssetData(token0, true, true, 0);

        // create teller role for enter/exit vault
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
        rolesAuthority.setUserRole(address(teller), 2, true);

        // create role for executing intents on the teller
        rolesAuthority.setRoleCapability(
            42,
            address(teller),
            bytes4(keccak256(abi.encodePacked("deposit(((address,bool,uint256,uint256,uint256),address,uint256,bytes),bool)"))),
            true
        );
        rolesAuthority.setRoleCapability(
            42,
            address(teller),
            bytes4(keccak256(abi.encodePacked("withdraw(((address,bool,uint256,uint256,uint256),address,uint256,bytes))"))),
            true
        );
        rolesAuthority.setRoleCapability(
            42,
            address(teller),
            bytes4(keccak256(abi.encodePacked("bulkActions(((address,bool,uint256,uint256,uint256),address,uint256,bytes)[],bool[])"))),
            true
        );
        // set users after deployment for now

        // Make Signature Cancellation Public
        rolesAuthority.setPublicCapability(address(teller), IntentsTeller.cancelSignature.selector, true);

        // set share lock period
        teller.setShareLockPeriod(1 days);

        // set teller as before transfer hook for vault
        boringVault.setBeforeTransferHook(address(teller));

        // TODO: deploy and grant roles to the teller, complete all other prod roles
        // TODO: ownership xfer

        // TEMP ITEMS FOR TESTING
        // grant rebalancer role
        rolesAuthority.setUserRole(0x4b716b2d4a352738B72a181F051b24De20317Ff3, 7, true);
        // set 1inch aggregator
        manager.setAggregator(0x111111125421cA6dc452d289314280a0f8842A65, true);

        vm.stopBroadcast();
    }
}
