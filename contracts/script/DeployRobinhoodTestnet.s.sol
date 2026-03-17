// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {DobValidatorRegistry} from "../src/DobValidatorRegistry.sol";
import {DobRwaVault} from "../src/DobRwaVault.sol";
import {DobLPRegistry} from "../src/DobLPRegistry.sol";
import {RWAToken} from "../src/DobTokenFactory.sol";
import {MockUSDC} from "../src/RWAFaucet.sol";

/// @notice Deploy the Dobprotocol core stack on Robinhood Chain Testnet.
///         No Uniswap V4 PoolManager available yet — deploys core protocol
///         (USDC, Registry, Vault, LPRegistry, 4 RWA tokens) without hook/pool.
///         Hook + pool can be added once Uniswap V4 is deployed on Robinhood Chain.
///
/// Usage:
///   source .env && forge script script/DeployRobinhoodTestnet.s.sol:DeployRobinhoodTestnet \
///     --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast -vvv
contract DeployRobinhoodTestnet is Script {
    MockUSDC usdc;
    DobValidatorRegistry registry;
    DobRwaVault vault;
    DobLPRegistry lpRegistry;
    RWAToken dct;
    RWAToken sft;
    RWAToken ret;
    RWAToken pwg;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("Deployer:", deployer);
        console2.log("Chain: Robinhood Testnet (46630)");

        vm.startBroadcast(pk);

        _deployCore(deployer);
        _createAssets(deployer);
        _configureProtocol();
        _seedLiquidity(deployer);

        vm.stopBroadcast();

        _logAddresses();
    }

    function _deployCore(address deployer) internal {
        usdc = new MockUSDC(deployer);
        registry = new DobValidatorRegistry(deployer);
        vault = new DobRwaVault(address(registry), 1 days, deployer);
        lpRegistry = new DobLPRegistry(address(usdc), deployer);

        console2.log("USDC:", address(usdc));
        console2.log("Registry:", address(registry));
        console2.log("Vault (dUSDC):", address(vault));
        console2.log("LPRegistry:", address(lpRegistry));
    }

    function _createAssets(address deployer) internal {
        dct = new RWAToken("Datacenter Token", "DCT", 10_000e18, deployer, address(usdc));
        sft = new RWAToken("Solar Farm Token", "SFT", 20_000e18, deployer, address(usdc));
        ret = new RWAToken("Real Estate Token", "RET", 4_000e18, deployer, address(usdc));
        pwg = new RWAToken("Power Grid Token", "PWG", 15_000e18, deployer, address(usdc));

        dct.configureSale(100e18, true);
        sft.configureSale(50e18, true);
        ret.configureSale(250e18, true);
        pwg.configureSale(75e18, true);

        console2.log("DCT:", address(dct));
        console2.log("SFT:", address(sft));
        console2.log("RET:", address(ret));
        console2.log("PWG:", address(pwg));
    }

    function _configureProtocol() internal {
        registry.setPrice(address(dct), 100e18);
        registry.setPrice(address(sft), 50e18);
        registry.setPrice(address(ret), 250e18);
        registry.setPrice(address(pwg), 75e18);

        vault.addApprovedAsset(address(dct));
        vault.addApprovedAsset(address(sft));
        vault.addApprovedAsset(address(ret));
        vault.addApprovedAsset(address(pwg));

        registry.setGlobalLiquidationCap(10_000_000e18);
    }

    function _seedLiquidity(address deployer) internal {
        // Mint USDC to deployer for testing
        usdc.mint(deployer, 5_000_000e18);
        console2.log("Minted 5M USDC to deployer");
    }

    function _logAddresses() internal view {
        console2.log("\n=== Robinhood Testnet Deployment ===");
        console2.log("REGISTRY=", address(registry));
        console2.log("VAULT=", address(vault));
        console2.log("LP_REGISTRY=", address(lpRegistry));
        console2.log("USDC=", address(usdc));
        console2.log("DCT=", address(dct));
        console2.log("SFT=", address(sft));
        console2.log("RET=", address(ret));
        console2.log("PWG=", address(pwg));

        console2.log("\n=== Note ===");
        console2.log("Hook not deployed - Uniswap V4 PoolManager not yet on Robinhood Chain.");
        console2.log("Once PoolManager is available, deploy DobPegHook and wire it in:");
        console2.log("  registry.setHook(hookAddr)");
        console2.log("  vault.setHook(hookAddr)");
        console2.log("  lpRegistry.setHook(hookAddr)");
        console2.log("  lpRegistry.setRegistry(address(registry))");
    }
}
