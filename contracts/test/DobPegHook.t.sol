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

    /*//////////////////////////////////////////////////////////////
                      LP-ONLY MODE TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetLpOnlyMode() public {
        assertEq(hook.lpOnlyMode(address(rwaToken)), false, "Should default to false");
        hook.setLpOnlyMode(address(rwaToken), true);
        assertEq(hook.lpOnlyMode(address(rwaToken)), true, "Should be true after set");
        hook.setLpOnlyMode(address(rwaToken), false);
        assertEq(hook.lpOnlyMode(address(rwaToken)), false, "Should be false after unset");
    }

    function testSetLpOnlyModeOnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DobPegHook.OnlyAdmin.selector);
        hook.setLpOnlyMode(address(rwaToken), true);
    }

    function testLpOnlyModeRevertsWithNoLpRegistry() public {
        // Enable lpOnly without an LP registry set
        hook.setLpOnlyMode(address(rwaToken), true);

        // Deposit RWA to get dobRWA
        _depositRwa(1e18);

        // Swap with hookData (triggers lpOnly path)
        bytes memory hookData = abi.encode(address(rwaToken));
        vm.expectRevert(); // InsufficientLiquidity wrapped by PoolManager
        _swapDobRwaToUsdc(1000e18, hookData);
    }

    function testLpOnlyModeDisabledUsesHookReserves() public {
        // lpOnly is false by default — swap should use hook USDC as usual
        _depositRwa(1e18);
        uint256 usdcBefore = usdcToken.balanceOf(address(this));

        bytes memory hookData = abi.encode(address(rwaToken));
        _swapDobRwaToUsdc(1000e18, hookData);

        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, 1000e18, "Should fill from hook reserves at 1:1");
    }

    /*//////////////////////////////////////////////////////////////
                     RWA RESALE MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function testListRwaForSale() public {
        // Give user some RWA tokens directly
        rwaToken.mint(address(this), 500e18);
        rwaToken.approve(address(hook), 500e18);

        hook.listRwaForSale(address(rwaToken), 100e18);

        assertEq(hook.totalRwaListed(address(rwaToken)), 100e18, "Total listed should be 100");
        assertEq(hook.rwaForSale(address(this), address(rwaToken)), 100e18, "Seller listed amount");
        assertEq(hook.getRwaSellersCount(address(rwaToken)), 1, "Should have 1 seller");
        assertEq(rwaToken.balanceOf(address(hook)), 100e18, "Hook should hold the RWA");
    }

    function testListRwaForSaleRevertsUnapproved() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        rogue.mint(address(this), 100e18);
        rogue.approve(address(hook), 100e18);

        vm.expectRevert(DobPegHook.TokenNotApproved.selector);
        hook.listRwaForSale(address(rogue), 100e18);
    }

    function testListRwaForSaleRevertsZero() public {
        vm.expectRevert(DobPegHook.ZeroAmount.selector);
        hook.listRwaForSale(address(rwaToken), 0);
    }

    function testDelistRwa() public {
        rwaToken.mint(address(this), 100e18);
        rwaToken.approve(address(hook), 100e18);

        hook.listRwaForSale(address(rwaToken), 100e18);

        uint256 balBefore = rwaToken.balanceOf(address(this));
        hook.delistRwa(address(rwaToken), 40e18);
        uint256 balAfter = rwaToken.balanceOf(address(this));

        assertEq(balAfter - balBefore, 40e18, "Should return 40 RWA tokens");
        assertEq(hook.rwaForSale(address(this), address(rwaToken)), 60e18, "60 should remain listed");
        assertEq(hook.totalRwaListed(address(rwaToken)), 60e18, "Total listed should be 60");
    }

    function testDelistRwaFull() public {
        rwaToken.mint(address(this), 100e18);
        rwaToken.approve(address(hook), 100e18);
        hook.listRwaForSale(address(rwaToken), 100e18);

        hook.delistRwa(address(rwaToken), 100e18);

        assertEq(hook.rwaForSale(address(this), address(rwaToken)), 0, "Should be 0 listed");
        assertEq(hook.getRwaSellersCount(address(rwaToken)), 0, "Seller should be removed");
    }

    function testDelistRwaRevertsInsufficientListed() public {
        vm.expectRevert(DobPegHook.InsufficientListedRwa.selector);
        hook.delistRwa(address(rwaToken), 100e18);
    }

    function testBuyListedRwa() public {
        // Setup: seller lists RWA
        rwaToken.mint(address(this), 10e18);
        rwaToken.approve(address(hook), 10e18);
        hook.listRwaForSale(address(rwaToken), 10e18);

        // Setup: buyer
        address buyer = address(0xBEEF);
        uint256 usdcNeeded = (10e18 * RWA_PRICE) / 1e18; // 10 * 100k = 1M
        usdcToken.mint(buyer, usdcNeeded + 100_000e18); // extra for fee

        vm.startPrank(buyer);
        usdcToken.approve(address(hook), type(uint256).max);
        hook.buyListedRwa(address(rwaToken), 10e18);
        vm.stopPrank();

        // Buyer should have the RWA
        assertEq(rwaToken.balanceOf(buyer), 10e18, "Buyer should have 10 RWA");
        // Seller should have received USDC
        assertEq(usdcToken.balanceOf(address(this)), usdcNeeded + 500_000e18, "Seller should receive USDC at oracle price");
        // Listed amounts should be zero
        assertEq(hook.totalRwaListed(address(rwaToken)), 0, "No RWA should be listed");
        assertEq(hook.getRwaSellersCount(address(rwaToken)), 0, "Seller array should be empty");
    }

    function testBuyListedRwaWithFee() public {
        // Set 1% swap fee
        hook.setSwapFee(100);

        // Seller lists
        rwaToken.mint(address(this), 1e18);
        rwaToken.approve(address(hook), 1e18);
        hook.listRwaForSale(address(rwaToken), 1e18);

        // Buyer
        address buyer = address(0xBEEF);
        uint256 usdcCost = (1e18 * RWA_PRICE) / 1e18; // 100k
        uint256 fee = (usdcCost * 100) / 10000; // 1% = 1k
        usdcToken.mint(buyer, usdcCost + fee);

        uint256 lpPoolBefore = hook.totalLpUsdc();

        vm.startPrank(buyer);
        usdcToken.approve(address(hook), type(uint256).max);
        hook.buyListedRwa(address(rwaToken), 1e18);
        vm.stopPrank();

        uint256 lpPoolAfter = hook.totalLpUsdc();
        assertEq(lpPoolAfter - lpPoolBefore, fee, "Fee should accrue to LP pool");
    }

    function testBuyListedRwaRevertsNoListings() public {
        vm.expectRevert(DobPegHook.NoListingsAvailable.selector);
        hook.buyListedRwa(address(rwaToken), 1e18);
    }

    function testBuyListedRwaRevertsStaleOracle() public {
        rwaToken.mint(address(this), 1e18);
        rwaToken.approve(address(hook), 1e18);
        hook.listRwaForSale(address(rwaToken), 1e18);

        // Warp past oracle staleness
        vm.warp(block.timestamp + MAX_DELAY + 1);

        address buyer = address(0xBEEF);
        usdcToken.mint(buyer, 200_000e18);
        vm.startPrank(buyer);
        usdcToken.approve(address(hook), type(uint256).max);
        vm.expectRevert(DobPegHook.OracleStale.selector);
        hook.buyListedRwa(address(rwaToken), 1e18);
        vm.stopPrank();
    }

    function testBuyListedRwaFIFO() public {
        // Seller A lists first
        address sellerA = address(0xAAA);
        rwaToken.mint(sellerA, 5e18);
        vm.startPrank(sellerA);
        rwaToken.approve(address(hook), 5e18);
        hook.listRwaForSale(address(rwaToken), 5e18);
        vm.stopPrank();

        // Seller B lists second
        address sellerB = address(0xBBB);
        rwaToken.mint(sellerB, 5e18);
        vm.startPrank(sellerB);
        rwaToken.approve(address(hook), 5e18);
        hook.listRwaForSale(address(rwaToken), 5e18);
        vm.stopPrank();

        // Buyer buys 7 RWA (should drain A=5, partial B=2)
        address buyer = address(0xBEEF);
        uint256 cost = (7e18 * RWA_PRICE) / 1e18;
        usdcToken.mint(buyer, cost);
        vm.startPrank(buyer);
        usdcToken.approve(address(hook), type(uint256).max);
        hook.buyListedRwa(address(rwaToken), 7e18);
        vm.stopPrank();

        // Seller A fully drained, Seller B has 3 remaining
        assertEq(hook.rwaForSale(sellerA, address(rwaToken)), 0, "A should be fully sold");
        assertEq(hook.rwaForSale(sellerB, address(rwaToken)), 3e18, "B should have 3 remaining");

        // Seller A should have received USDC for 5 tokens
        uint256 paymentA = (5e18 * RWA_PRICE) / 1e18;
        assertEq(usdcToken.balanceOf(sellerA), paymentA, "A should receive payment for 5 tokens");
    }

    function testMultipleListAndBuy() public {
        // Same seller lists multiple times
        rwaToken.mint(address(this), 50e18);
        rwaToken.approve(address(hook), 50e18);

        hook.listRwaForSale(address(rwaToken), 20e18);
        hook.listRwaForSale(address(rwaToken), 30e18);

        assertEq(hook.rwaForSale(address(this), address(rwaToken)), 50e18, "Total for seller");
        assertEq(hook.totalRwaListed(address(rwaToken)), 50e18, "Total listed");
        // Should still be just 1 seller in array (not duplicated)
        assertEq(hook.getRwaSellersCount(address(rwaToken)), 1, "Should not duplicate seller");
    }

    /*//////////////////////////////////////////////////////////////
                     ADMIN TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function testTransferAdmin() public {
        address newAdmin = address(0xABCD);
        hook.transferAdmin(newAdmin);
        assertEq(hook.admin(), newAdmin, "Admin should be transferred");
    }

    function testTransferAdminOnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DobPegHook.OnlyAdmin.selector);
        hook.transferAdmin(address(0xABCD));
    }

    function testTransferAdminRevertZeroAddress() public {
        vm.expectRevert(DobPegHook.ZeroAddress.selector);
        hook.transferAdmin(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function testPauseBlocksSwaps() public {
        _depositRwa(1e18);
        hook.pause();

        vm.expectRevert(); // ContractPaused wrapped by PoolManager
        _swapDobRwaToUsdc(1000e18, Constants.ZERO_BYTES);
    }

    function testUnpauseReenablesSwaps() public {
        _depositRwa(1e18);
        hook.pause();
        hook.unpause();

        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        _swapDobRwaToUsdc(1000e18, Constants.ZERO_BYTES);
        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, 1000e18, "Swap should work after unpause");
    }

    function testPauseOnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DobPegHook.OnlyAdmin.selector);
        hook.pause();
    }

    function testPauseBlocksDeposit() public {
        hook.pause();

        vm.expectRevert(DobPegHook.ContractPaused.selector);
        hook.depositUsdc(1000e18);
    }

    function testPauseBlocksListRwa() public {
        hook.pause();
        rwaToken.mint(address(this), 10e18);
        rwaToken.approve(address(hook), 10e18);

        vm.expectRevert(DobPegHook.ContractPaused.selector);
        hook.listRwaForSale(address(rwaToken), 10e18);
    }

    function testPauseBlocksBuyListedRwa() public {
        // List before pause
        rwaToken.mint(address(this), 10e18);
        rwaToken.approve(address(hook), 10e18);
        hook.listRwaForSale(address(rwaToken), 10e18);

        hook.pause();

        address buyer = address(0xBEEF);
        usdcToken.mint(buyer, 2_000_000e18);
        vm.startPrank(buyer);
        usdcToken.approve(address(hook), type(uint256).max);
        vm.expectRevert(DobPegHook.ContractPaused.selector);
        hook.buyListedRwa(address(rwaToken), 1e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                     PROTOCOL FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetProtocolFee() public {
        hook.setProtocolFee(100); // 1%
        assertEq(hook.protocolFeeBps(), 100, "Protocol fee should be 100 bps");
    }

    function testSetProtocolFeeOnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DobPegHook.OnlyAdmin.selector);
        hook.setProtocolFee(100);
    }

    function testSetProtocolFeeRevertTooHigh() public {
        vm.expectRevert(DobPegHook.FeeTooHigh.selector);
        hook.setProtocolFee(501); // >5% max
    }

    function testProtocolFeeAppliedOnSell() public {
        hook.setProtocolFee(100); // 1%

        _depositRwa(1e18);
        uint256 swapAmount = 10_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 reserveBefore = hook.protocolReserveUsdc();

        _swapDobRwaToUsdc(swapAmount, Constants.ZERO_BYTES);

        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        uint256 reserveAfter = hook.protocolReserveUsdc();

        // Protocol fee = 1% of amountOut (which is 10,000 at 1:1)
        uint256 expectedFee = (swapAmount * 100) / 10000; // 100 USDC
        uint256 expectedOut = swapAmount - expectedFee;

        assertEq(usdcAfter - usdcBefore, expectedOut, "Should deduct protocol fee from output");
        assertEq(reserveAfter - reserveBefore, expectedFee, "Protocol fee should accrue to reserve");
    }

    function testProtocolFeeAppliedOnResaleBuy() public {
        hook.setProtocolFee(100); // 1%

        // Seller lists
        rwaToken.mint(address(this), 1e18);
        rwaToken.approve(address(hook), 1e18);
        hook.listRwaForSale(address(rwaToken), 1e18);

        uint256 reserveBefore = hook.protocolReserveUsdc();

        // Buyer
        address buyer = address(0xBEEF);
        usdcToken.mint(buyer, 200_000e18);
        vm.startPrank(buyer);
        usdcToken.approve(address(hook), type(uint256).max);
        hook.buyListedRwa(address(rwaToken), 1e18);
        vm.stopPrank();

        uint256 reserveAfter = hook.protocolReserveUsdc();
        uint256 usdcCost = (1e18 * RWA_PRICE) / 1e18;
        uint256 expectedPFee = (usdcCost * 100) / 10000;

        assertEq(reserveAfter - reserveBefore, expectedPFee, "Protocol fee should accrue on resale buy");
    }

    /*//////////////////////////////////////////////////////////////
                  SLIPPAGE PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testSlippageProtectionPasses() public {
        _depositRwa(1e18);
        uint256 swapAmount = 10_000e18;

        // Encode (rwaToken, minAmountOut) — minAmountOut = 9,999 should pass at 1:1
        bytes memory hookData = abi.encode(address(rwaToken), uint256(9_999e18));
        uint256 usdcBefore = usdcToken.balanceOf(address(this));

        _swapDobRwaToUsdc(swapAmount, hookData);

        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, swapAmount, "Swap should pass slippage check");
    }

    function testSlippageProtectionReverts() public {
        hook.setProtocolFee(500); // 5% fee to trigger slippage

        _depositRwa(1e18);
        uint256 swapAmount = 10_000e18;

        // minAmountOut = 10,000 but fee will reduce to 9,500
        bytes memory hookData = abi.encode(address(rwaToken), swapAmount);

        vm.expectRevert(); // SlippageExceeded wrapped by PoolManager
        _swapDobRwaToUsdc(swapAmount, hookData);
    }

    /*//////////////////////////////////////////////////////////////
               ORACLE PRICE BOUNDS TESTS
    //////////////////////////////////////////////////////////////*/

    function testMaxPriceChangeBounds() public {
        registry.setMaxPriceChange(1000); // 10% max change

        // Current price is 100,000e18. 10% = 10,000e18 max delta
        // Set new price within bounds
        registry.setPrice(address(rwaToken), 109_000e18);
        (uint256 price,) = registry.getPrice(address(rwaToken));
        assertEq(price, 109_000e18, "Price should update within bounds");
    }

    function testMaxPriceChangeRevertsTooLarge() public {
        registry.setMaxPriceChange(1000); // 10% max change

        // Try to set price 20% higher — should revert
        vm.expectRevert(DobValidatorRegistry.PriceChangeTooLarge.selector);
        registry.setPrice(address(rwaToken), 120_001e18);
    }

    function testEmergencySetPriceBypassesBounds() public {
        registry.setMaxPriceChange(1000); // 10% max change

        // emergencySetPrice bypasses the limit
        registry.emergencySetPrice(address(rwaToken), 200_000e18);
        (uint256 price,) = registry.getPrice(address(rwaToken));
        assertEq(price, 200_000e18, "Emergency set should bypass bounds");
    }

    /*//////////////////////////////////////////////////////////////
              REGISTRY PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function testRegistryPauseBlocksSetPrice() public {
        registry.pause();
        vm.expectRevert(DobValidatorRegistry.ContractPaused.selector);
        registry.setPrice(address(rwaToken), 50_000e18);
    }

    function testRegistryPauseBlocksSetLiquidation() public {
        registry.pause();
        vm.expectRevert(DobValidatorRegistry.ContractPaused.selector);
        registry.setLiquidationParams(address(rwaToken), 2000, 500_000e18);
    }

    function testRegistryUnpause() public {
        registry.pause();
        registry.unpause();
        // Should work after unpause
        registry.setPrice(address(rwaToken), 90_000e18);
        (uint256 price,) = registry.getPrice(address(rwaToken));
        assertEq(price, 90_000e18, "Should update after unpause");
    }

    /*//////////////////////////////////////////////////////////////
                  VAULT PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function testVaultPauseBlocksDeposit() public {
        vault.pause();
        vm.expectRevert(DobRwaVault.ContractPaused.selector);
        vault.deposit(address(rwaToken), 1e18);
    }

    function testVaultUnpauseAllowsDeposit() public {
        vault.pause();
        vault.unpause();
        // Should work after unpause
        vault.deposit(address(rwaToken), 1e18);
        assertGt(ERC20(address(vault)).balanceOf(address(this)), 0, "Should mint after unpause");
    }

    /*//////////////////////////////////////////////////////////////
               USDC CLAIM REDEMPTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testUsdcClaimBalanceView() public view {
        uint256 bal = hook.usdcClaimBalance();
        // Before any buys, should be 0
        assertEq(bal, 0, "No claims initially");
    }

    function testRedeemUsdcClaimsOnlyAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DobPegHook.OnlyAdmin.selector);
        hook.redeemUsdcClaims(1000e18);
    }

    function testRedeemUsdcClaimsRevertZero() public {
        vm.expectRevert(DobPegHook.ZeroAmount.selector);
        hook.redeemUsdcClaims(0);
    }
}
