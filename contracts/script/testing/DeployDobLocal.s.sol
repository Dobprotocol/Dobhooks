// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {Deployers} from "test/utils/Deployers.sol";

import {DobValidatorRegistry} from "../../src/DobValidatorRegistry.sol";
import {DobRwaVault} from "../../src/DobRwaVault.sol";
import {DobPegHook} from "../../src/DobPegHook.sol";

/// @title DeployDobLocal
/// @notice Deploys the full Dobprotocol stack to Anvil and runs an E2E flow.
///         Key insight: V4 infra (PoolManager, Permit2, etc) and the Hook address
///         all require bytecode at specific addresses, done via anvil_setCode RPC.
///         These happen OUTSIDE vm.startBroadcast() since they aren't normal txs.
///         Only standard CREATE and CALL txs go inside the broadcast.
contract DeployDobLocal is Script, Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 constant RWA_PRICE = 100_000e18;
    uint48 constant MAX_DELAY = 1 days;

    DobValidatorRegistry registry;
    DobRwaVault vault;
    DobPegHook hook;
    MockERC20 rwaToken;
    MockERC20 usdcToken;
    PoolKey poolKey;
    address hookAddress;

    /// @dev Etch bytecode both in simulation EVM and on Anvil
    function _etch(address target, bytes memory bytecode) internal override {
        vm.etch(target, bytecode);
        vm.rpc(
            "anvil_setCode",
            string.concat('["', vm.toString(target), '","', vm.toString(bytecode), '"]')
        );
    }

    /// @dev Set a storage slot on Anvil
    function _setStorage(address target, uint256 slot, bytes32 value) internal {
        vm.store(target, bytes32(slot), value);
        vm.rpc(
            "anvil_setStorageAt",
            string.concat(
                '["', vm.toString(target), '","',
                vm.toString(bytes32(slot)), '","',
                vm.toString(value), '"]'
            )
        );
    }

    function run() external {
        console.log("======================================");
        console.log("  Dobprotocol Local Deployment");
        console.log("======================================");

        // ═══════════════════════════════════════════════════
        // Phase 1: Pre-broadcast — etch V4 infrastructure
        // ═══════════════════════════════════════════════════
        console.log("[1/11] Deploying V4 infrastructure via anvil_setCode...");
        deployArtifacts();
        console.log("  PoolManager:     ", address(poolManager));
        console.log("  SwapRouter:      ", address(swapRouter));
        console.log("  Permit2:         ", address(permit2));

        // ═══════════════════════════════════════════════════
        // Phase 2: broadcast — deploy protocol via normal txs
        // ═══════════════════════════════════════════════════
        vm.startBroadcast();

        console.log("[2/11] Deploying DobValidatorRegistry...");
        registry = new DobValidatorRegistry(msg.sender);
        console.log("  Registry:        ", address(registry));

        console.log("[3/11] Deploying DobRwaVault...");
        vault = new DobRwaVault(address(registry), MAX_DELAY, msg.sender);
        console.log("  Vault/dobRWA:    ", address(vault));

        console.log("[4/11] Deploying Mock tokens...");
        rwaToken = new MockERC20("Datacenter Token", "DCT", 18);
        usdcToken = new MockERC20("USD Coin", "USDC", 18);
        console.log("  RWA (DCT):       ", address(rwaToken));
        console.log("  USDC:            ", address(usdcToken));

        // Deploy hook at a normal address first (to get the bytecode with immutables)
        console.log("[5/11] Deploying DobPegHook...");

        vm.stopBroadcast(); // pause broadcast for hook deployment

        // Compute the flag address
        hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144)
        );

        // Use deployCodeTo (cheatcode) to deploy hook at the flag address in simulation
        bytes memory constructorArgs = abi.encode(poolManager, vault, usdcToken, registry, msg.sender);
        deployCodeTo("DobPegHook.sol:DobPegHook", constructorArgs, hookAddress);
        hook = DobPegHook(hookAddress);

        // Sync to Anvil: copy runtime bytecode (includes immutables) to the flag address
        vm.rpc(
            "anvil_setCode",
            string.concat('["', vm.toString(hookAddress), '","', vm.toString(hookAddress.code), '"]')
        );
        console.log("  Hook etched at:  ", hookAddress);

        vm.startBroadcast(); // resume broadcast

        console.log("[6/11] Authorizing hook...");
        registry.setHook(hookAddress);
        vault.setHook(hookAddress);

        console.log("[7/11] Creating dobRWA/USDC pool...");
        Currency currency0;
        Currency currency1;
        if (address(vault) < address(usdcToken)) {
            currency0 = Currency.wrap(address(vault));
            currency1 = Currency.wrap(address(usdcToken));
        } else {
            currency0 = Currency.wrap(address(usdcToken));
            currency1 = Currency.wrap(address(vault));
        }
        poolKey = PoolKey(currency0, currency1, 0, 1, IHooks(hook));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        console.log("  Pool initialized (1:1 sqrtPrice)");

        console.log("[8/11] Setting up approvals...");
        _doApprovals();

        console.log("[9/11] Setting oracle price ($100,000/DCT)...");
        registry.setPrice(address(rwaToken), RWA_PRICE);
        vault.addApprovedAsset(address(rwaToken));

        console.log("[10/11] Seeding USDC reserves (500k)...");
        usdcToken.mint(msg.sender, 1_000_000e18);
        usdcToken.approve(hookAddress, type(uint256).max);
        hook.seedUsdc(500_000e18);

        console.log("[11/11] Minting 100 DCT for user...");
        rwaToken.mint(msg.sender, 100e18);
        rwaToken.approve(address(vault), type(uint256).max);

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════
        // Print deployed addresses for the UI
        // ═══════════════════════════════════════════════════
        console.log("");
        console.log("======================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================");
        console.log("  ADDRESSES FOR UI CONFIG:");
        console.log("  PoolManager:       ", address(poolManager));
        console.log("  SwapRouter:        ", address(swapRouter));
        console.log("  Permit2:           ", address(permit2));
        console.log("  Registry:          ", address(registry));
        console.log("  Vault/dobRWA:      ", address(vault));
        console.log("  Hook:              ", hookAddress);
        console.log("  RWA (DCT):         ", address(rwaToken));
        console.log("  USDC:              ", address(usdcToken));
        console.log("  Deployer:          ", msg.sender);
    }

    function _doApprovals() internal {
        ERC20(address(vault)).approve(address(permit2), type(uint256).max);
        usdcToken.approve(address(permit2), type(uint256).max);
        ERC20(address(vault)).approve(address(swapRouter), type(uint256).max);
        usdcToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(address(usdcToken), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(address(vault), address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(usdcToken), address(poolManager), type(uint160).max, type(uint48).max);
    }
}
