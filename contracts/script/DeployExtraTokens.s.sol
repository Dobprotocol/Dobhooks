// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DobValidatorRegistry} from "../src/DobValidatorRegistry.sol";
import {DobRwaVault} from "../src/DobRwaVault.sol";
import {RWAToken} from "../src/DobTokenFactory.sol";

/// @notice Deploy the 6 additional RWA tokens (WFT, GLT, EVT, TBT, FLT, SCT).
///         Requires REGISTRY, VAULT, and USDC env vars from prior deployment.
///
/// Usage (Arb Sepolia):
///   source .env && forge script script/DeployExtraTokens.s.sol:DeployExtraTokens \
///     --rpc-url $ARB_SEPOLIA_RPC --broadcast -vvv
///
/// Usage (Robinhood):
///   source .env && forge script script/DeployExtraTokens.s.sol:DeployExtraTokens \
///     --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast -vvv
contract DeployExtraTokens is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdcAddr = vm.envAddress("USDC");
        address registryAddr = vm.envAddress("REGISTRY");
        address vaultAddr = vm.envAddress("VAULT");

        DobValidatorRegistry registry = DobValidatorRegistry(registryAddr);
        DobRwaVault vault = DobRwaVault(vaultAddr);

        console2.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        // WFT - Wind Farm Token
        RWAToken wft = new RWAToken("Wind Farm Token", "WFT", 8_000e18, deployer, usdcAddr);
        wft.configureSale(180e18, true);
        registry.setPrice(address(wft), 180e18);
        vault.addApprovedAsset(address(wft));
        console2.log("WFT:", address(wft));

        // GLT - Gold Reserve Token
        RWAToken glt = new RWAToken("Gold Reserve Token", "GLT", 30_000e18, deployer, usdcAddr);
        glt.configureSale(62e18, true);
        registry.setPrice(address(glt), 62e18);
        vault.addApprovedAsset(address(glt));
        console2.log("GLT:", address(glt));

        // EVT - EV Fleet Token
        RWAToken evt = new RWAToken("EV Fleet Token", "EVT", 12_000e18, deployer, usdcAddr);
        evt.configureSale(42e18, true);
        registry.setPrice(address(evt), 42e18);
        vault.addApprovedAsset(address(evt));
        console2.log("EVT:", address(evt));

        // TBT - Treasury Bond Token
        RWAToken tbt = new RWAToken("Treasury Bond Token", "TBT", 50_000e18, deployer, usdcAddr);
        tbt.configureSale(10e18, true);
        registry.setPrice(address(tbt), 10e18);
        vault.addApprovedAsset(address(tbt));
        console2.log("TBT:", address(tbt));

        // FLT - Farmland Token
        RWAToken flt = new RWAToken("Farmland Token", "FLT", 10_000e18, deployer, usdcAddr);
        flt.configureSale(85e18, true);
        registry.setPrice(address(flt), 85e18);
        vault.addApprovedAsset(address(flt));
        console2.log("FLT:", address(flt));

        // SCT - Shipping Container Token
        RWAToken sct = new RWAToken("Shipping Container Token", "SCT", 20_000e18, deployer, usdcAddr);
        sct.configureSale(28e18, true);
        registry.setPrice(address(sct), 28e18);
        vault.addApprovedAsset(address(sct));
        console2.log("SCT:", address(sct));

        vm.stopBroadcast();

        console2.log("\n=== Extra Tokens Deployed ===");
        console2.log("WFT=", address(wft));
        console2.log("GLT=", address(glt));
        console2.log("EVT=", address(evt));
        console2.log("TBT=", address(tbt));
        console2.log("FLT=", address(flt));
        console2.log("SCT=", address(sct));
    }
}
