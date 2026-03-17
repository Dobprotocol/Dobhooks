// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DobValidatorRegistry} from "../src/DobValidatorRegistry.sol";
import {DobRwaVault} from "../src/DobRwaVault.sol";
import {DobLPRegistry} from "../src/DobLPRegistry.sol";
import {DobDirectSwap} from "../src/DobDirectSwap.sol";
import {RWAToken} from "../src/DobTokenFactory.sol";
import {MockUSDC} from "../src/RWAFaucet.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Deploy the full Dobprotocol stack on Base Sepolia (no Uniswap V4).
///         Uses DobDirectSwap for 1:1 USDC<->dUSDC peg swaps.
///
/// Usage:
///   source .env
///   forge script script/DeployBaseSepolia.s.sol:DeployBaseSepolia \
///     --rpc-url $BASE_SEPOLIA_RPC --broadcast -vvv
contract DeployBaseSepolia is Script {
    MockUSDC usdc;
    DobValidatorRegistry registry;
    DobRwaVault vault;
    DobLPRegistry lpRegistry;
    DobDirectSwap directSwap;
    RWAToken dct;
    RWAToken sft;
    RWAToken ret;
    RWAToken pwg;
    // Extra tokens
    RWAToken wft;
    RWAToken glt;
    RWAToken evt;
    RWAToken tbt;
    RWAToken flt;
    RWAToken sct;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("Deployer:", deployer);
        console2.log("Chain: Base Sepolia (84532)");

        vm.startBroadcast(pk);

        // ── Core ──
        usdc = new MockUSDC(deployer);
        registry = new DobValidatorRegistry(deployer);
        vault = new DobRwaVault(address(registry), 1 days, deployer);
        lpRegistry = new DobLPRegistry(address(usdc), deployer);

        // ── 4 core RWA tokens ──
        dct = new RWAToken("Datacenter Token", "DCT", 10_000e18, deployer, address(usdc));
        sft = new RWAToken("Solar Farm Token", "SFT", 20_000e18, deployer, address(usdc));
        ret = new RWAToken("Real Estate Token", "RET", 4_000e18, deployer, address(usdc));
        pwg = new RWAToken("Power Grid Token", "PWG", 15_000e18, deployer, address(usdc));

        dct.configureSale(100e18, true);
        sft.configureSale(50e18, true);
        ret.configureSale(250e18, true);
        pwg.configureSale(75e18, true);

        // ── 6 extra tokens ──
        wft = new RWAToken("Wind Farm Token", "WFT", 12_000e18, deployer, address(usdc));
        glt = new RWAToken("Gold Linked Token", "GLT", 5_000e18, deployer, address(usdc));
        evt = new RWAToken("EV Fleet Token", "EVT", 8_000e18, deployer, address(usdc));
        tbt = new RWAToken("T-Bill Token", "TBT", 50_000e18, deployer, address(usdc));
        flt = new RWAToken("Farmland Token", "FLT", 3_000e18, deployer, address(usdc));
        sct = new RWAToken("Ship Cargo Token", "SCT", 6_000e18, deployer, address(usdc));

        wft.configureSale(80e18, true);
        glt.configureSale(1800e18, true);
        evt.configureSale(120e18, true);
        tbt.configureSale(100e18, true);
        flt.configureSale(200e18, true);
        sct.configureSale(150e18, true);

        // ── Oracle prices ──
        registry.setPrice(address(dct), 100e18);
        registry.setPrice(address(sft), 50e18);
        registry.setPrice(address(ret), 250e18);
        registry.setPrice(address(pwg), 75e18);
        registry.setPrice(address(wft), 80e18);
        registry.setPrice(address(glt), 1800e18);
        registry.setPrice(address(evt), 120e18);
        registry.setPrice(address(tbt), 100e18);
        registry.setPrice(address(flt), 200e18);
        registry.setPrice(address(sct), 150e18);

        // ── Approve assets in vault ──
        vault.addApprovedAsset(address(dct));
        vault.addApprovedAsset(address(sft));
        vault.addApprovedAsset(address(ret));
        vault.addApprovedAsset(address(pwg));
        vault.addApprovedAsset(address(wft));
        vault.addApprovedAsset(address(glt));
        vault.addApprovedAsset(address(evt));
        vault.addApprovedAsset(address(tbt));
        vault.addApprovedAsset(address(flt));
        vault.addApprovedAsset(address(sct));

        registry.setGlobalLiquidationCap(10_000_000e18);

        // ── DobDirectSwap (1:1 peg, no Uniswap V4) ──
        directSwap = new DobDirectSwap(address(usdc), address(vault), deployer);

        // Wire LP registry
        lpRegistry.setRegistry(address(registry));

        // Seed USDC
        usdc.mint(deployer, 5_000_000e18);
        usdc.approve(address(directSwap), 1_000_000e18);
        directSwap.seedUsdc(1_000_000e18);

        vm.stopBroadcast();

        // ── Log addresses ──
        console2.log("\n=== Base Sepolia Addresses ===");
        console2.log("USDC=", address(usdc));
        console2.log("REGISTRY=", address(registry));
        console2.log("VAULT=", address(vault));
        console2.log("LP_REGISTRY=", address(lpRegistry));
        console2.log("DIRECT_SWAP=", address(directSwap));
        console2.log("DCT=", address(dct));
        console2.log("SFT=", address(sft));
        console2.log("RET=", address(ret));
        console2.log("PWG=", address(pwg));
        console2.log("WFT=", address(wft));
        console2.log("GLT=", address(glt));
        console2.log("EVT=", address(evt));
        console2.log("TBT=", address(tbt));
        console2.log("FLT=", address(flt));
        console2.log("SCT=", address(sct));
    }
}
