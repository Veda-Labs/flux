// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Auth, Authority} from "@solmate/src/auth/Auth.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {UniswapV4FluxManager} from "src/managers/UniswapV4FluxManager.sol";
import {BoringVault} from "src/BoringVault.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {RolesAuthority, Authority} from "@solmate/src/auth/authorities/RolesAuthority.sol";

import {Test, stdStorage, StdStorage, stdError, console} from "@forge-std/Test.sol";

contract BoringDroneTest is Test {
    using Address for address;

    RolesAuthority internal rolesAuthority;
    BoringVault internal boringVault;
    UniswapV4FluxManager internal manager;
    address positionManager = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    ERC20 token0 = ERC20(address(0));
    ERC20 token1 = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

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

        rolesAuthority.setUserRole(0xF62849F9A0B5Bf2913b396098F7c7019b51A820a, 1, true);

        manager = new UniswapV4FluxManager(
            address(this), address(boringVault), address(token0), address(token1), positionManager
        );
    }

    // Expected sqrtPRiceX96  1568156260822541131850212282450855
    function testMinting() external {
        deal(address(boringVault), 3e18);
        deal(address(token1), address(boringVault), 10_000e6);

        // current tick for uniswap V3 pool 68456
        manager.mint(-887_270, 887_270, 51401006023, 3e18, 10_000e6, block.timestamp);

        uint256 exchangeRate = 2_644e9;
        (uint256 token0Balance, uint256 token1Balance) = manager.totalAssets(exchangeRate);
        console.log("Token 0 Balance", token0Balance);
        console.log("Token 1 Balance", token1Balance);
    }

    // ========================================= HELPER FUNCTIONS =========================================

    receive() external payable {}

    function _startFork(string memory rpcKey, uint256 blockNumber) internal returns (uint256 forkId) {
        forkId = vm.createFork(vm.envString(rpcKey), blockNumber);
        vm.selectFork(forkId);
    }
}
