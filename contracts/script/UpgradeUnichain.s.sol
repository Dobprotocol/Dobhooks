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
import {MockUSDC} from "../src/RWAFaucet.sol";

/// @notice Upgrade DobPegHook + DobLPRegistry on Unichain Sepolia.
///         Adds LP-only mode, RWA resale market, and ReentrancyGuard.
///         Keeps existing Registry, Vault, USDC, and RWA tokens.
///
/// Usage:
///   forge script script/UpgradeUnichain.s.sol:UpgradeUnichain \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast -vvv
contract UpgradeUnichain is Script {
    // ── Existing contracts (unchanged) ──
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    DobValidatorRegistry constant REGISTRY = DobValidatorRegistry(0x652E5572aF3a879D591a4DD289566bcF28BeA52B);
    DobRwaVault constant VAULT = DobRwaVault(0x5d38b9bD487D8a0ff7997dB953a68F650B242e00);
    MockUSDC constant USDC = MockUSDC(0x217f355497A67F5ef82cff105Fb14a84C9A9E071);
    DobPegHook constant OLD_HOOK = DobPegHook(0xf49aa3f7160e051813268e6fFD0f51E2909DA888);

    // ── New contracts ──
    DobLPRegistry newLpRegistry;
    DobPegHook newHook;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=== Upgrading Hook + LPRegistry on Unichain Sepolia ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        // 1. Drain USDC from old hook
        uint256 oldReserve = OLD_HOOK.protocolReserveUsdc();
        if (oldReserve > 0) {
            OLD_HOOK.withdrawProtocolReserve(oldReserve);
            console2.log("Drained from old hook:", oldReserve);
        }

        // 2. Deploy new LPRegistry
        newLpRegistry = new DobLPRegistry(address(USDC), deployer);
        console2.log("New LPRegistry:", address(newLpRegistry));

        // 3. Deploy new Hook (CREATE2 with HookMiner)
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER), VAULT, USDC, REGISTRY, deployer
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(DobPegHook).creationCode, constructorArgs
        );

        newHook = new DobPegHook{salt: salt}(
            IPoolManager(POOL_MANAGER), VAULT, USDC, REGISTRY, deployer
        );
        require(address(newHook) == hookAddr, "Hook address mismatch");
        console2.log("New Hook:", address(newHook));

        // 4. Rewire existing contracts to new hook
        REGISTRY.setHook(address(newHook));
        VAULT.setHook(address(newHook));
        console2.log("Registry + Vault rewired to new hook");

        // 5. Wire new LPRegistry
        newLpRegistry.setHook(address(newHook));
        newLpRegistry.setRegistry(address(REGISTRY));
        newHook.setLPRegistry(address(newLpRegistry));
        console2.log("LPRegistry wired");

        // 6. Seed new hook with USDC
        USDC.approve(address(newHook), 1_000_000e18);
        newHook.seedUsdc(1_000_000e18);
        console2.log("Seeded 1M USDC into new hook");

        // 7. Initialize new pool
        Currency currency0;
        Currency currency1;
        if (address(VAULT) < address(USDC)) {
            currency0 = Currency.wrap(address(VAULT));
            currency1 = Currency.wrap(address(USDC));
        } else {
            currency0 = Currency.wrap(address(USDC));
            currency1 = Currency.wrap(address(VAULT));
        }

        PoolKey memory poolKey = PoolKey(currency0, currency1, 0, 1, IHooks(newHook));
        IPoolManager(POOL_MANAGER).initialize(poolKey, Constants.SQRT_PRICE_1_1);
        console2.log("Pool initialized with new hook");

        vm.stopBroadcast();

        // Log results
        console2.log("\n=== Upgrade Complete ===");
        console2.log("OLD_HOOK=", address(OLD_HOOK), "(retired)");
        console2.log("NEW_HOOK=", address(newHook));
        console2.log("NEW_LP_REGISTRY=", address(newLpRegistry));
        console2.log("\n=== Unchanged ===");
        console2.log("REGISTRY=", address(REGISTRY));
        console2.log("VAULT=", address(VAULT));
        console2.log("USDC=", address(USDC));
        console2.log("POOL_MANAGER=", POOL_MANAGER);
        console2.log("\nUpdate frontend ADDR() with new Hook + LPRegistry addresses");
    }
}
