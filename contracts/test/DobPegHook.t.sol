// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {DobValidatorRegistry} from "../src/DobValidatorRegistry.sol";
import {DobRwaVault} from "../src/DobRwaVault.sol";
import {DobPegHook} from "../src/DobPegHook.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract DobPegHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // --- Protocol contracts ---
    DobValidatorRegistry registry;
    DobRwaVault vault;
    DobPegHook hook;

    // --- Tokens ---
    MockERC20 rwaToken;   // Simulated ERC-3643 RWA token (e.g., Datacenter Token)
    MockERC20 usdcToken;  // Simulated USDC

    // --- Pool ---
    PoolKey poolKey;
    PoolId poolId;

    // --- Constants ---
    uint256 constant RWA_PRICE = 100_000e18; // $100,000 per RWA token
    uint48 constant MAX_DELAY = 1 days;

    function setUp() public {
        // ───── 1. Deploy V4 infrastructure ─────
        deployArtifactsAndLabel();

        // ───── 2. Deploy protocol contracts ─────
        registry = new DobValidatorRegistry(address(this));
        vault = new DobRwaVault(address(registry), MAX_DELAY, address(this));

        // ───── 3. Deploy mock tokens ─────
        rwaToken = new MockERC20("Datacenter Token", "DCT", 18);
        usdcToken = new MockERC20("USD Coin", "USDC", 18);

        // ───── 4. Deploy the hook with correct address flags ─────
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144) // Namespace to avoid collisions
        );
        bytes memory constructorArgs =
            abi.encode(poolManager, vault, usdcToken, registry, address(this));
        deployCodeTo("DobPegHook.sol:DobPegHook", constructorArgs, flags);
        hook = DobPegHook(flags);

        // ───── 5. Authorize hook in registry and vault ─────
        registry.setHook(address(hook));
        vault.setHook(address(hook));

        // ───── 6. Set up token ordering for the pool ─────
        // Uniswap V4 requires currency0 < currency1
        Currency currency0;
        Currency currency1;
        if (address(vault) < address(usdcToken)) {
            currency0 = Currency.wrap(address(vault));
            currency1 = Currency.wrap(address(usdcToken));
        } else {
            currency0 = Currency.wrap(address(usdcToken));
            currency1 = Currency.wrap(address(vault));
        }

        // ───── 7. Create the pool (fee=0, tickSpacing=1 for peg) ─────
        poolKey = PoolKey(currency0, currency1, 0, 1, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // ───── 8. Approve tokens via permit2 & router ─────
        // dobRWA approvals
        ERC20(address(vault)).approve(address(permit2), type(uint256).max);
        ERC20(address(vault)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(vault), address(poolManager), type(uint160).max, type(uint48).max);

        // USDC approvals
        usdcToken.approve(address(permit2), type(uint256).max);
        usdcToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(usdcToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(usdcToken), address(poolManager), type(uint160).max, type(uint48).max);

        // ───── 9. Oracle & Vault setup ─────
        registry.setPrice(address(rwaToken), RWA_PRICE);
        vault.addApprovedAsset(address(rwaToken));

        // ───── 10. Seed hook with USDC reserves ─────
        usdcToken.mint(address(this), 1_000_000e18);
        usdcToken.approve(address(hook), type(uint256).max);
        hook.seedUsdc(500_000e18);

        // ───── 11. Mint RWA tokens for the test user ─────
        rwaToken.mint(address(this), 100e18);
        rwaToken.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         ORACLE TESTS
    //////////////////////////////////////////////////////////////*/

    function testOracleSetPrice() public view {
        (uint256 price, uint48 updatedAt) = registry.getPrice(address(rwaToken));
        assertEq(price, RWA_PRICE, "Oracle price mismatch");
        assertEq(updatedAt, uint48(block.timestamp), "Oracle timestamp mismatch");
    }

    function testOracleRevertOnMissingPrice() public {
        vm.expectRevert(DobValidatorRegistry.PriceNotSet.selector);
        registry.getPrice(address(usdcToken)); // no price set for USDC
    }

    function testOracleRevertOnZeroPrice() public {
        vm.expectRevert(DobValidatorRegistry.ZeroPrice.selector);
        registry.setPrice(address(rwaToken), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         VAULT TESTS
    //////////////////////////////////////////////////////////////*/

    function testVaultDeposit() public {
        uint256 depositAmount = 1e18; // 1 RWA token
        uint256 expectedDobRwa = (depositAmount * RWA_PRICE) / 1e18; // 100,000 dobRWA

        uint256 balanceBefore = ERC20(address(vault)).balanceOf(address(this));
        vault.deposit(address(rwaToken), depositAmount);
        uint256 balanceAfter = ERC20(address(vault)).balanceOf(address(this));

        assertEq(balanceAfter - balanceBefore, expectedDobRwa, "Incorrect dobRWA minted");
        assertEq(rwaToken.balanceOf(address(vault)), depositAmount, "RWA not in vault");
    }

    function testVaultRevertUnapprovedAsset() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        rogue.mint(address(this), 1e18);
        rogue.approve(address(vault), 1e18);

        vm.expectRevert(DobRwaVault.AssetNotApproved.selector);
        vault.deposit(address(rogue), 1e18);
    }

    function testVaultRevertStaleOracle() public {
        // Warp time forward past the oracle delay
        vm.warp(block.timestamp + MAX_DELAY + 1);

        vm.expectRevert(DobRwaVault.OracleStale.selector);
        vault.deposit(address(rwaToken), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                         HOOK SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function testPegSwapDobRwaToUsdc() public {
        // --- Deposit RWA to get dobRWA ---
        vault.deposit(address(rwaToken), 1e18); // Gets 100,000 dobRWA

        uint256 swapAmount = 1000e18; // Swap 1,000 dobRWA for USDC
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 dobRwaBefore = ERC20(address(vault)).balanceOf(address(this));

        // Determine swap direction based on token ordering
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(vault);

        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        uint256 dobRwaAfter = ERC20(address(vault)).balanceOf(address(this));

        // At 1:1 peg, user should receive exactly `swapAmount` USDC
        assertEq(usdcAfter - usdcBefore, swapAmount, "USDC received != swap amount (peg violated)");
        assertEq(dobRwaBefore - dobRwaAfter, swapAmount, "dobRWA not deducted correctly");
    }

    function testPegSwapUsdcToDobRwa() public {
        // --- Seed hook with some dobRWA for the reverse swap ---
        vault.deposit(address(rwaToken), 1e18); // Gets 100,000 dobRWA
        ERC20(address(vault)).approve(address(hook), type(uint256).max);
        // Transfer some dobRWA to the hook for reverse swaps
        ERC20(address(vault)).transfer(address(hook), 50_000e18);

        // --- Give user some USDC ---
        uint256 swapAmount = 1000e18;
        usdcToken.mint(address(this), swapAmount);

        uint256 dobRwaBefore = ERC20(address(vault)).balanceOf(address(this));

        // Determine swap direction: we want USDC → dobRWA
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(usdcToken);

        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 dobRwaAfter = ERC20(address(vault)).balanceOf(address(this));

        // At 1:1 peg, user should receive exactly `swapAmount` dobRWA
        assertEq(dobRwaAfter - dobRwaBefore, swapAmount, "dobRWA received != swap amount (peg violated)");
    }

    /*//////////////////////////////////////////////////////////////
                     ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertUnauthorizedPoolInit() public {
        Currency c0;
        Currency c1;
        if (address(vault) < address(usdcToken)) {
            c0 = Currency.wrap(address(vault));
            c1 = Currency.wrap(address(usdcToken));
        } else {
            c0 = Currency.wrap(address(usdcToken));
            c1 = Currency.wrap(address(vault));
        }

        // Deploy a second hook at a different address for this test
        address flags2 = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x6666 << 144)
        );
        bytes memory constructorArgs =
            abi.encode(poolManager, vault, usdcToken, registry, address(this));
        deployCodeTo("DobPegHook.sol:DobPegHook", constructorArgs, flags2);
        DobPegHook hook2 = DobPegHook(flags2);

        PoolKey memory key2 = PoolKey(c0, c1, 100, 10, IHooks(hook2));

        // Non-admin tries to initialize — PoolManager wraps the hook's revert
        vm.prank(address(0xdead));
        vm.expectRevert(); // PoolManager wraps in WrappedError
        poolManager.initialize(key2, Constants.SQRT_PRICE_1_1);
    }

    /*//////////////////////////////////////////////////////////////
                     LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: deposit RWA and return the dobRWA amount
    function _depositRwa(uint256 rwaAmount) internal returns (uint256 dobRwaAmount) {
        uint256 before = ERC20(address(vault)).balanceOf(address(this));
        vault.deposit(address(rwaToken), rwaAmount);
        dobRwaAmount = ERC20(address(vault)).balanceOf(address(this)) - before;
    }

    /// @dev Helper: perform a swap with optional hookData for liquidation
    function _swapDobRwaToUsdc(uint256 swapAmount, bytes memory hookData) internal {
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(vault);

        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function testLiquidationSwapWithPenalty() public {
        // --- Setup: deposit RWA to get dobRWA ---
        _depositRwa(1e18); // Gets 100,000 dobRWA

        // --- Enable liquidation with 20% penalty ---
        registry.setLiquidationParams(address(rwaToken), 2000, 500_000e18);
        registry.setGlobalLiquidationCap(1_000_000e18);

        uint256 swapAmount = 10_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 dobRwaBefore = ERC20(address(vault)).balanceOf(address(this));

        // Swap with liquidation hookData
        bytes memory hookData = abi.encode(address(rwaToken));
        _swapDobRwaToUsdc(swapAmount, hookData);

        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        uint256 dobRwaAfter = ERC20(address(vault)).balanceOf(address(this));

        // User should receive 80% (penalty = 20%)
        uint256 expectedUsdc = (swapAmount * 8000) / 10000; // 8,000 USDC
        assertEq(usdcAfter - usdcBefore, expectedUsdc, "USDC received != expected (penalty not applied)");
        assertEq(dobRwaBefore - dobRwaAfter, swapAmount, "Full dobRWA input not deducted");

        // Verify liquidation was recorded
        (, , , uint256 liquidatedAmount) = registry.getLiquidationParams(address(rwaToken));
        assertEq(liquidatedAmount, swapAmount, "Liquidation amount not recorded");

        // Verify global liquidation was recorded
        assertEq(registry.globalLiquidatedAmount(), swapAmount, "Global liquidation not recorded");
    }

    function testLiquidationCapEnforced() public {
        _depositRwa(5e18); // Gets 500,000 dobRWA

        // Enable liquidation with 10% penalty, 50,000 cap
        registry.setLiquidationParams(address(rwaToken), 1000, 50_000e18);
        registry.setGlobalLiquidationCap(1_000_000e18);

        bytes memory hookData = abi.encode(address(rwaToken));

        // Try to swap 100,000 — exceeds 50,000 cap
        vm.expectRevert(); // LiquidationCapExceeded wrapped by PoolManager
        _swapDobRwaToUsdc(100_000e18, hookData);
    }

    function testLiquidationCapPartialFill() public {
        _depositRwa(5e18); // Gets 500,000 dobRWA

        // Enable liquidation with 10% penalty, cap = 30,000
        registry.setLiquidationParams(address(rwaToken), 1000, 30_000e18);
        registry.setGlobalLiquidationCap(1_000_000e18);

        bytes memory hookData = abi.encode(address(rwaToken));

        // First swap: 20,000 — within cap
        _swapDobRwaToUsdc(20_000e18, hookData);

        (, , , uint256 liquidatedAfterFirst) = registry.getLiquidationParams(address(rwaToken));
        assertEq(liquidatedAfterFirst, 20_000e18, "First liquidation not recorded");

        // Second swap: 10,000 — exactly at cap (20k + 10k = 30k)
        _swapDobRwaToUsdc(10_000e18, hookData);

        (, , , uint256 liquidatedAfterSecond) = registry.getLiquidationParams(address(rwaToken));
        assertEq(liquidatedAfterSecond, 30_000e18, "Second liquidation not recorded");

        // Third swap: 1 wei — exceeds cap
        vm.expectRevert(); // LiquidationCapExceeded
        _swapDobRwaToUsdc(1e18, hookData);
    }

    function testGlobalLiquidationCapEnforced() public {
        _depositRwa(5e18); // Gets 500,000 dobRWA

        // Per-asset cap is large, but global cap is small
        registry.setLiquidationParams(address(rwaToken), 1000, 500_000e18);
        registry.setGlobalLiquidationCap(20_000e18); // global cap = 20k

        bytes memory hookData = abi.encode(address(rwaToken));

        // Swap 20,000 — exactly at global cap
        _swapDobRwaToUsdc(20_000e18, hookData);
        assertEq(registry.globalLiquidatedAmount(), 20_000e18, "Global amount not tracked");

        // Next swap exceeds global cap
        vm.expectRevert(); // GlobalLiquidationCapExceeded
        _swapDobRwaToUsdc(1e18, hookData);
    }

    function testNormalSwapUnaffectedByLiquidation() public {
        _depositRwa(1e18); // Gets 100,000 dobRWA

        // Enable liquidation for the RWA token
        registry.setLiquidationParams(address(rwaToken), 2000, 500_000e18);
        registry.setGlobalLiquidationCap(1_000_000e18);

        uint256 swapAmount = 5_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));

        // Swap WITHOUT hookData — normal 1:1 peg, liquidation not triggered
        _swapDobRwaToUsdc(swapAmount, Constants.ZERO_BYTES);

        uint256 usdcAfter = usdcToken.balanceOf(address(this));

        // Should receive full 1:1 amount
        assertEq(usdcAfter - usdcBefore, swapAmount, "Normal swap should be 1:1 even with liquidation enabled");

        // Liquidation counters should not change
        (, , , uint256 liquidatedAmount) = registry.getLiquidationParams(address(rwaToken));
        assertEq(liquidatedAmount, 0, "Liquidation should not be recorded for normal swap");
    }

    function testDisableLiquidationRevertsToNormalPeg() public {
        _depositRwa(1e18); // Gets 100,000 dobRWA

        // Enable then disable liquidation
        registry.setLiquidationParams(address(rwaToken), 2000, 500_000e18);
        registry.setGlobalLiquidationCap(1_000_000e18);
        registry.disableLiquidation(address(rwaToken));

        uint256 swapAmount = 10_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));

        // Swap WITH hookData — but liquidation is disabled, so 1:1 peg
        bytes memory hookData = abi.encode(address(rwaToken));
        _swapDobRwaToUsdc(swapAmount, hookData);

        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, swapAmount, "Disabled liquidation should revert to 1:1 peg");
    }

    function testOnlyHookCanRecordLiquidation() public {
        registry.setLiquidationParams(address(rwaToken), 2000, 500_000e18);

        // Non-hook address tries to record liquidation
        vm.prank(address(0xdead));
        vm.expectRevert(DobValidatorRegistry.OnlyHook.selector);
        registry.recordLiquidation(address(rwaToken), 1000e18);
    }

    function testLiquidationInvalidPenaltyReverts() public {
        // 0 penalty should revert
        vm.expectRevert(DobValidatorRegistry.InvalidPenalty.selector);
        registry.setLiquidationParams(address(rwaToken), 0, 500_000e18);

        // >10000 penalty should revert
        vm.expectRevert(DobValidatorRegistry.InvalidPenalty.selector);
        registry.setLiquidationParams(address(rwaToken), 10001, 500_000e18);
    }

    function testLiquidationZeroCapReverts() public {
        vm.expectRevert(DobValidatorRegistry.ZeroCap.selector);
        registry.setLiquidationParams(address(rwaToken), 2000, 0);
    }
}
