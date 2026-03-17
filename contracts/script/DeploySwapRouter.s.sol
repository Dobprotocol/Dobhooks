// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DobSwapRouter} from "../src/DobSwapRouter.sol";

/// @notice Deploy DobSwapRouter and configure the pool key.
///
/// Usage:
///   source .env && forge script script/DeploySwapRouter.s.sol:DeploySwapRouter \
///     --rpc-url $ARB_SEPOLIA_RPC --broadcast -vvv
contract DeploySwapRouter is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address vault = vm.envAddress("VAULT");
        address usdc = vm.envAddress("USDC");
        address hook = vm.envAddress("HOOK");

        console2.log("PoolManager:", poolManager);
        console2.log("Vault (dobRWA):", vault);
        console2.log("USDC:", usdc);
        console2.log("Hook:", hook);

        vm.startBroadcast(pk);

        DobSwapRouter router = new DobSwapRouter(poolManager);
        console2.log("DobSwapRouter:", address(router));

        // Configure pool key: fee=0, tickSpacing=1 (matching DeployArbitrumSepolia)
        router.setPoolKey(address(vault), address(usdc), 0, 1, hook);
        console2.log("Pool key set");

        vm.stopBroadcast();

        console2.log("\n=== Add to .env ===");
        console2.log("ROUTER=", address(router));
    }
}
