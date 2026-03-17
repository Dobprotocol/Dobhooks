// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ReactiveOracleSync} from "../src/ReactiveOracleSync.sol";

/// @notice Deploy ReactiveOracleSync on Reactive Network Lasna Testnet (chain 5318007).
///         Subscribes to DobValidatorRegistry events on Unichain Sepolia (1301)
///         and sends cross-chain callbacks to OracleAlertReceiver.
///
/// Partner Integration: Reactive Network (https://reactive.network)
///
/// Prerequisites:
///   - DobValidatorRegistry deployed on Unichain Sepolia (set REGISTRY env var)
///   - OracleAlertReceiver deployed on Unichain Sepolia (set ALERT_RECEIVER env var)
///   - lREACT tokens on Lasna Testnet (get from faucet)
///
/// Usage:
///   export REACTIVE_RPC=https://lasna-rpc.rnk.dev/
///   export REGISTRY=<registry-address-on-unichain>
///   export ALERT_RECEIVER=<alert-receiver-address-on-unichain>
///
///   forge script script/DeployReactive.s.sol:DeployReactive \
///     --rpc-url $REACTIVE_RPC --broadcast -vvv
contract DeployReactive is Script {
    /// @notice Unichain Sepolia chain ID (origin chain being monitored)
    uint256 constant UNICHAIN_SEPOLIA = 1301;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Read deployed addresses from env
        address registry = vm.envAddress("REGISTRY");
        address alertReceiver = vm.envAddress("ALERT_RECEIVER");

        console2.log("=== Deploying to Reactive Network Lasna Testnet (5318007) ===");
        console2.log("Deployer:", deployer);
        console2.log("Origin Chain: Unichain Sepolia (1301)");
        console2.log("Registry (origin):", registry);
        console2.log("AlertReceiver (callback target):", alertReceiver);

        vm.startBroadcast(pk);

        ReactiveOracleSync sync = new ReactiveOracleSync(
            UNICHAIN_SEPOLIA,
            registry,
            alertReceiver
        );

        console2.log("\n=== Reactive Network Deployment ===");
        console2.log("ReactiveOracleSync:", address(sync));
        console2.log("Subscribed to PriceUpdated + LiquidationEnabled events");
        console2.log("Callbacks will be sent to:", alertReceiver, "on Unichain Sepolia");

        // Set example alert thresholds (80% of initial prices)
        // These would trigger callbacks if prices drop below these levels
        // In production, thresholds would be set by Dobprotocol governance

        vm.stopBroadcast();

        console2.log("\n=== Next Steps ===");
        console2.log("1. Set alert thresholds: sync.setAlertThreshold(token, threshold)");
        console2.log("2. Oracle updates on Unichain will be automatically monitored");
        console2.log("3. Price drops below threshold -> callback to OracleAlertReceiver");
    }
}
