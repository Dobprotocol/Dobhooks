// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {DobLPRegistry} from "../src/DobLPRegistry.sol";
import {DobPooledLN} from "../src/DobPooledLN.sol";
import {MockUSDC} from "../src/RWAFaucet.sol";

/// @notice Deploy DobPooledLN (shared Liquidity Node) on Unichain Sepolia.
///         Requires existing LPRegistry deployment.
///
/// Usage:
///   forge script script/DeployPooledLN.s.sol:DeployPooledLN \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast -vvv
contract DeployPooledLN is Script {
    // ── Existing contracts (from UpgradeUnichain deployment) ──
    // Update these addresses after UpgradeUnichain runs
    DobLPRegistry constant LP_REGISTRY = DobLPRegistry(0xE77C5957ae8bA5E902E0c038a8d2ea6cbE1763aF);
    MockUSDC constant USDC = MockUSDC(0x217f355497A67F5ef82cff105Fb14a84C9A9E071);

    // ── RWA Token addresses (Unichain Sepolia) ──
    address constant DCT = 0xb802B347FBb832d3E3Ee4e35E0A4a5ac4Be1ca49;
    address constant SFT = 0x0b2f54B1aae1b909b3F452b179f026B8b0bd6837;
    address constant RET = 0x4A51e0dCc1eB07e8E72B1438c3E1B12C0ACaE0CD;
    address constant PWG = 0x3f0f8e2c21D7F46FA87db6b69c3E5E3a3A08A11b;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=== Deploying DobPooledLN (Main Liquidity Node) ===");
        console2.log("Deployer (operator):", deployer);

        vm.startBroadcast(pk);

        // 1. Deploy the Pooled LN
        DobPooledLN pooledLN = new DobPooledLN(
            address(USDC),
            address(LP_REGISTRY),
            deployer,       // owner = deployer (Dobprotocol admin)
            100e18           // min deposit = 100 USDC
        );
        console2.log("DobPooledLN deployed:", address(pooledLN));

        // 2. Seed initial USDC and register in LP Registry
        uint256 initialCapital = 100_000e18;
        USDC.approve(address(pooledLN), initialCapital);
        // Transfer USDC to pooledLN first (it needs balance to register)
        USDC.transfer(address(pooledLN), initialCapital);
        pooledLN.registerInRegistry(initialCapital);
        console2.log("Registered with", initialCapital / 1e18, "USDC");

        // 3. Back core RWA assets with default 3% discount
        uint16 defaultDiscount = 300; // 3%
        uint256 allocationPerAsset = 20_000e18;
        uint256 maxExposure = 500_000e18;

        pooledLN.backAsset(DCT, 0, defaultDiscount, maxExposure, allocationPerAsset);
        console2.log("Backed DCT (3% discount, 20k allocated)");

        pooledLN.backAsset(SFT, 0, defaultDiscount, maxExposure, allocationPerAsset);
        console2.log("Backed SFT (3% discount, 20k allocated)");

        vm.stopBroadcast();

        console2.log("\n=== Deployment Complete ===");
        console2.log("POOLED_LN=", address(pooledLN));
        console2.log("LP_REGISTRY=", address(LP_REGISTRY));
        console2.log("USDC=", address(USDC));
        console2.log("\nAnyone can now call pooledLN.deposit() to add liquidity");
        console2.log("Admin can call updateDiscount() to adjust rates dynamically");
    }
}
