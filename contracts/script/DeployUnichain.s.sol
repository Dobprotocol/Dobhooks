// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {DobValidatorRegistry} from "../src/DobValidatorRegistry.sol";
import {DobRwaVault} from "../src/DobRwaVault.sol";
import {DobPegHook} from "../src/DobPegHook.sol";
import {DobLPRegistry} from "../src/DobLPRegistry.sol";
import {RWAToken} from "../src/DobTokenFactory.sol";
import {MockUSDC} from "../src/RWAFaucet.sol";
import {OracleAlertReceiver} from "../src/OracleAlertReceiver.sol";

/// @notice Deploy the full Dobprotocol stack on Unichain Sepolia (chain 1301).
///         Includes Uniswap V4 DobPegHook + OracleAlertReceiver for Reactive Network callbacks.
///
/// Partner Integrations:
///   - Unichain: Full Uniswap V4 hook deployment (DobPegHook custom accounting)
///   - Reactive Network: OracleAlertReceiver receives cross-chain oracle alerts
///
/// Usage:
///   forge script script/DeployUnichain.s.sol:DeployUnichain \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast -vvv
contract DeployUnichain is Script {
    // Uniswap V4 PoolManager on Unichain Sepolia (1301)
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    // CREATE2 Deployer Proxy (standard across all EVM chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Reactive Network Callback Proxy on Unichain Sepolia
    // See: https://docs.reactive.network/origins-and-destinations
    address constant REACTIVE_CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    // Deployed addresses (set during run)
    MockUSDC usdc;
    DobValidatorRegistry registry;
    DobRwaVault vault;
    DobLPRegistry lpRegistry;
    DobPegHook hook;
    OracleAlertReceiver alertReceiver;
    RWAToken dct;
    RWAToken sft;
    RWAToken ret;
    RWAToken pwg;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=== Deploying to Unichain Sepolia (1301) ===");
        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", POOL_MANAGER);

        vm.startBroadcast(pk);

        _deployCore(deployer);
        _createAssets(deployer);
        _configureProtocol(deployer);
        _deployHook(deployer);
        _initPool(deployer);
        _deployAlertReceiver();

        vm.stopBroadcast();

        _logAddresses(deployer);
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

    function _configureProtocol(address) internal {
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

    function _deployHook(address deployer) internal {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER), vault, usdc, registry, deployer
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(DobPegHook).creationCode, constructorArgs
        );

        hook = new DobPegHook{salt: salt}(
            IPoolManager(POOL_MANAGER), vault, usdc, registry, deployer
        );
        require(address(hook) == hookAddr, "Hook address mismatch");
        console2.log("Hook:", address(hook));

        // Wire hook into protocol
        registry.setHook(address(hook));
        vault.setHook(address(hook));
        lpRegistry.setHook(address(hook));
        lpRegistry.setRegistry(address(registry));
        hook.setLPRegistry(address(lpRegistry));

        // Seed USDC reserves
        usdc.mint(deployer, 5_000_000e18);
        usdc.approve(address(hook), 1_000_000e18);
        hook.seedUsdc(1_000_000e18);
    }

    function _initPool(address) internal {
        Currency currency0;
        Currency currency1;
        if (address(vault) < address(usdc)) {
            currency0 = Currency.wrap(address(vault));
            currency1 = Currency.wrap(address(usdc));
        } else {
            currency0 = Currency.wrap(address(usdc));
            currency1 = Currency.wrap(address(vault));
        }

        PoolKey memory poolKey = PoolKey(currency0, currency1, 0, 1, IHooks(hook));
        IPoolManager(POOL_MANAGER).initialize(poolKey, Constants.SQRT_PRICE_1_1);
        console2.log("Pool initialized on Unichain Sepolia V4");
    }

    /// @notice Deploy OracleAlertReceiver for Reactive Network cross-chain callbacks
    function _deployAlertReceiver() internal {
        alertReceiver = new OracleAlertReceiver(REACTIVE_CALLBACK_PROXY);
        console2.log("OracleAlertReceiver:", address(alertReceiver));
    }

    function _logAddresses(address) internal view {
        console2.log("\n=== Unichain Sepolia Deployment ===");
        console2.log("POOL_MANAGER=", POOL_MANAGER);
        console2.log("HOOK=", address(hook));
        console2.log("REGISTRY=", address(registry));
        console2.log("VAULT=", address(vault));
        console2.log("LP_REGISTRY=", address(lpRegistry));
        console2.log("USDC=", address(usdc));
        console2.log("ALERT_RECEIVER=", address(alertReceiver));
        console2.log("DCT=", address(dct));
        console2.log("SFT=", address(sft));
        console2.log("RET=", address(ret));
        console2.log("PWG=", address(pwg));

        console2.log("\n=== Partner Integration: Reactive Network ===");
        console2.log("OracleAlertReceiver deployed at:", address(alertReceiver));
        console2.log("Callback Proxy:", REACTIVE_CALLBACK_PROXY);
        console2.log("Next: Deploy ReactiveOracleSync on Reactive Lasna Testnet (5318007)");
        console2.log("  with args: originChainId=1301, registry=", address(registry));
        console2.log("  callbackTarget=", address(alertReceiver));

        console2.log("\n=== Partner Integration: Unichain ===");
        console2.log("DobPegHook (Uniswap V4 Custom Accounting) deployed at:", address(hook));
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("Pool initialized with 1:1 peg (SQRT_PRICE_1_1)");
    }
}
