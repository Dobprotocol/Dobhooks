// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {DobValidatorRegistry} from "../src/DobValidatorRegistry.sol";
import {DobRwaVault} from "../src/DobRwaVault.sol";
import {DobPegHook} from "../src/DobPegHook.sol";
import {DobLPRegistry} from "../src/DobLPRegistry.sol";

contract DobLPRegistryTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // --- Protocol contracts ---
    DobValidatorRegistry registry;
    DobRwaVault vault;
    DobPegHook hook;
    DobLPRegistry lpRegistry;

    // --- Tokens ---
    MockERC20 rwaToken;
    MockERC20 usdcToken;

    // --- Pool ---
    PoolKey poolKey;
    PoolId poolId;

    // --- LP addresses ---
    address constant LP1 = address(0x1111);
    address constant LP2 = address(0x2222);
    address constant LP3 = address(0x3333);

    // --- Constants ---
    uint256 constant RWA_PRICE = 100_000e18;
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
            ) ^ (0x5555 << 144)
        );
        bytes memory constructorArgs =
            abi.encode(poolManager, vault, usdcToken, registry, address(this));
        deployCodeTo("DobPegHook.sol:DobPegHook", constructorArgs, flags);
        hook = DobPegHook(flags);

        // ───── 5. Deploy LP Registry ─────
        lpRegistry = new DobLPRegistry(address(usdcToken), address(this));

        // ───── 6. Authorize hook + LP registry ─────
        registry.setHook(address(hook));
        vault.setHook(address(hook));
        lpRegistry.setHook(address(hook));
        lpRegistry.setRegistry(address(registry));
        hook.setLPRegistry(address(lpRegistry));

        // ───── 7. Set up token ordering for the pool ─────
        Currency currency0;
        Currency currency1;
        if (address(vault) < address(usdcToken)) {
            currency0 = Currency.wrap(address(vault));
            currency1 = Currency.wrap(address(usdcToken));
        } else {
            currency0 = Currency.wrap(address(usdcToken));
            currency1 = Currency.wrap(address(vault));
        }

        // ───── 8. Create the pool (fee=0, tickSpacing=1 for peg) ─────
        poolKey = PoolKey(currency0, currency1, 0, 1, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // ───── 9. Approve tokens via permit2 & router ─────
        ERC20(address(vault)).approve(address(permit2), type(uint256).max);
        ERC20(address(vault)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(vault), address(poolManager), type(uint160).max, type(uint48).max);

        usdcToken.approve(address(permit2), type(uint256).max);
        usdcToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(usdcToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(usdcToken), address(poolManager), type(uint160).max, type(uint48).max);

        // ───── 10. Oracle & Vault setup ─────
        registry.setPrice(address(rwaToken), RWA_PRICE);
        vault.addApprovedAsset(address(rwaToken));

        // ───── 11. Seed hook with USDC reserves (protocol fallback) ─────
        usdcToken.mint(address(this), 1_000_000e18);
        usdcToken.approve(address(hook), type(uint256).max);
        hook.seedUsdc(500_000e18);

        // ───── 12. Mint RWA tokens for the test user ─────
        rwaToken.mint(address(this), 100e18);
        rwaToken.approve(address(vault), type(uint256).max);

        // ───── 13. Fund LPs with USDC ─────
        usdcToken.mint(LP1, 200_000e18);
        usdcToken.mint(LP2, 100_000e18);
        usdcToken.mint(LP3, 50_000e18);

        vm.prank(LP1);
        usdcToken.approve(address(lpRegistry), type(uint256).max);
        vm.prank(LP2);
        usdcToken.approve(address(lpRegistry), type(uint256).max);
        vm.prank(LP3);
        usdcToken.approve(address(lpRegistry), type(uint256).max);

        // ───── 14. Enable liquidation for testing ─────
        registry.setLiquidationParams(address(rwaToken), 2000, 500_000e18); // 20% penalty
        registry.setGlobalLiquidationCap(1_000_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                    LP REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRegisterLP() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        (uint256 deposited, uint256 available, uint48 registeredAt, bool active) = lpRegistry.positions(LP1);
        assertEq(deposited, 10_000e18, "Incorrect deposit");
        assertEq(available, 10_000e18, "Incorrect available");
        assertTrue(active, "Should be active");
        assertEq(registeredAt, uint48(block.timestamp), "Incorrect timestamp");
    }

    function testRevertRegisterBelowMin() public {
        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.BelowMinDeposit.selector);
        lpRegistry.register(50e18); // below 100e18 minimum
    }

    function testRevertRegisterAlreadyRegistered() public {
        vm.prank(LP1);
        lpRegistry.register(1_000e18);

        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.AlreadyRegistered.selector);
        lpRegistry.register(1_000e18);
    }

    function testDepositMore() public {
        vm.prank(LP1);
        lpRegistry.register(1_000e18);

        vm.prank(LP1);
        lpRegistry.depositMore(500e18);

        (uint256 deposited, uint256 available,,) = lpRegistry.positions(LP1);
        assertEq(deposited, 1_500e18);
        assertEq(available, 1_500e18);
    }

    /*//////////////////////////////////////////////////////////////
                     ASSET BACKING TESTS
    //////////////////////////////////////////////////////////////*/

    function testBackAsset() public {
        vm.prank(LP1);
        lpRegistry.register(50_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(
            address(rwaToken),
            80_000e18,     // minOraclePrice: $80,000
            1500,          // minPenaltyBps: 15%
            100_000e18,    // maxExposure: 100k dobRWA
            30_000e18      // usdcAllocation: 30k USDC
        );

        DobLPRegistry.AssetBacking memory backing = lpRegistry.getBacking(LP1, address(rwaToken));
        assertTrue(backing.active, "Backing should be active");
        assertEq(backing.minOraclePrice, 80_000e18);
        assertEq(backing.minPenaltyBps, 1500);
        assertEq(backing.maxExposure, 100_000e18);
        assertEq(backing.usdcAllocated, 30_000e18);
        assertEq(backing.usdcUsed, 0);

        (, uint256 available,,) = lpRegistry.positions(LP1);
        assertEq(available, 20_000e18, "Available should be reduced");

        assertEq(lpRegistry.getAssetBackerCount(address(rwaToken)), 1);
    }

    function testRevertBackAssetInsufficientUsdc() public {
        vm.prank(LP1);
        lpRegistry.register(1_000e18);

        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.InsufficientAvailableUsdc.selector);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100e18, 5_000e18);
    }

    function testRevertBackAssetBelowMinAllocation() public {
        vm.prank(LP1);
        lpRegistry.register(1_000e18);

        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.BelowMinAllocation.selector);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100e18, 10e18); // below 50e18
    }

    function testRevertBackAssetAlreadyBacking() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100e18, 1_000e18);

        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.AlreadyBacking.selector);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100e18, 1_000e18);
    }

    function testUpdateConditions() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 80_000e18, 1500, 100_000e18, 5_000e18);

        vm.prank(LP1);
        lpRegistry.updateConditions(address(rwaToken), 90_000e18, 2000, 200_000e18);

        DobLPRegistry.AssetBacking memory backing = lpRegistry.getBacking(LP1, address(rwaToken));
        assertEq(backing.minOraclePrice, 90_000e18);
        assertEq(backing.minPenaltyBps, 2000);
        assertEq(backing.maxExposure, 200_000e18);
    }

    function testStopBackingHealthyAsset() public {
        // Disable liquidation so the asset is healthy
        registry.disableLiquidation(address(rwaToken));

        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100_000e18, 5_000e18);

        (, uint256 availableBefore,,) = lpRegistry.positions(LP1);
        assertEq(availableBefore, 5_000e18);

        vm.prank(LP1);
        lpRegistry.stopBacking(address(rwaToken));

        (, uint256 availableAfter,,) = lpRegistry.positions(LP1);
        assertEq(availableAfter, 10_000e18, "Unused USDC should be fully returned");
        assertEq(lpRegistry.getAssetBackerCount(address(rwaToken)), 0, "Backer should be removed");
    }

    function testStopBackingDistressedAssetReserve() public {
        // Asset is distressed (liquidation enabled in setUp)
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100_000e18, 5_000e18);

        vm.prank(LP1);
        lpRegistry.stopBacking(address(rwaToken));

        // 5,000 unused USDC: 67% returned (3,350), 33% reserved (1,650)
        uint256 reserveAmount = (5_000e18 * 3300) / 10000; // 1,650
        uint256 freeAmount = 5_000e18 - reserveAmount;      // 3,350

        (, uint256 available,,) = lpRegistry.positions(LP1);
        assertEq(available, 5_000e18 + freeAmount, "Should get 67% back + original available");

        // Check reserve hold exists
        DobLPRegistry.ReserveHold[] memory holds = lpRegistry.getReserveHolds(LP1);
        assertEq(holds.length, 1, "Should have 1 reserve hold");
        assertEq(holds[0].amount, reserveAmount, "Reserve amount incorrect");
        assertEq(holds[0].rwaToken, address(rwaToken), "Reserve asset incorrect");
    }

    function testReleaseReserveWhenAssetHealthy() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100_000e18, 5_000e18);

        vm.prank(LP1);
        lpRegistry.stopBacking(address(rwaToken));

        uint256 reserveAmount = (5_000e18 * 3300) / 10000;

        // Can't release yet — asset still distressed
        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.ReserveStillLocked.selector);
        lpRegistry.releaseReserve(0);

        // Asset becomes healthy
        registry.disableLiquidation(address(rwaToken));

        (, uint256 availableBefore,,) = lpRegistry.positions(LP1);

        vm.prank(LP1);
        lpRegistry.releaseReserve(0);

        (, uint256 availableAfter,,) = lpRegistry.positions(LP1);
        assertEq(availableAfter - availableBefore, reserveAmount, "Reserve should be released");

        // Hold should be removed
        DobLPRegistry.ReserveHold[] memory holds = lpRegistry.getReserveHolds(LP1);
        assertEq(holds.length, 0, "Hold should be removed");
    }

    function testReleaseReserveAfterDelay() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100_000e18, 5_000e18);

        vm.prank(LP1);
        lpRegistry.stopBacking(address(rwaToken));

        uint256 reserveAmount = (5_000e18 * 3300) / 10000;

        // Asset still distressed, but wait 7 days
        vm.warp(block.timestamp + 7 days + 1);

        (, uint256 availableBefore,,) = lpRegistry.positions(LP1);

        vm.prank(LP1);
        lpRegistry.releaseReserve(0);

        (, uint256 availableAfter,,) = lpRegistry.positions(LP1);
        assertEq(availableAfter - availableBefore, reserveAmount, "Reserve should be released after delay");
    }

    function testIncreaseAllocation() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100_000e18, 3_000e18);

        vm.prank(LP1);
        lpRegistry.increaseAllocation(address(rwaToken), 2_000e18);

        DobLPRegistry.AssetBacking memory backing = lpRegistry.getBacking(LP1, address(rwaToken));
        assertEq(backing.usdcAllocated, 5_000e18);

        (, uint256 available,,) = lpRegistry.positions(LP1);
        assertEq(available, 5_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                       WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testWithdrawalFlow() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        uint256 balanceBefore = usdcToken.balanceOf(LP1);

        // Request
        vm.prank(LP1);
        lpRegistry.requestWithdrawal(5_000e18);

        (uint256 amount, uint48 requestedAt) = lpRegistry.withdrawalRequests(LP1);
        assertEq(amount, 5_000e18);
        assertEq(requestedAt, uint48(block.timestamp));

        // Can't execute before delay
        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.WithdrawalNotReady.selector);
        lpRegistry.executeWithdrawal();

        // Warp past delay
        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(LP1);
        lpRegistry.executeWithdrawal();

        uint256 balanceAfter = usdcToken.balanceOf(LP1);
        assertEq(balanceAfter - balanceBefore, 5_000e18, "USDC not received");

        (uint256 deposited, uint256 available,,) = lpRegistry.positions(LP1);
        assertEq(deposited, 5_000e18);
        assertEq(available, 5_000e18);
    }

    function testCancelWithdrawal() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.requestWithdrawal(5_000e18);

        vm.prank(LP1);
        lpRegistry.cancelWithdrawal();

        (, uint256 available,,) = lpRegistry.positions(LP1);
        assertEq(available, 10_000e18, "USDC should be returned to available");
    }

    function testRevertWithdrawAllocatedUsdc() public {
        vm.prank(LP1);
        lpRegistry.register(10_000e18);

        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 100_000e18, 8_000e18);

        // Only 2,000 available, trying to withdraw 5,000
        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.InsufficientAvailableUsdc.selector);
        lpRegistry.requestWithdrawal(5_000e18);
    }

    /*//////////////////////////////////////////////////////////////
               LIQUIDATION SWAP WITH LP FILL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: deposit RWA and return the dobRWA amount
    function _depositRwa(uint256 rwaAmount) internal returns (uint256 dobRwaAmount) {
        uint256 before = ERC20(address(vault)).balanceOf(address(this));
        vault.deposit(address(rwaToken), rwaAmount);
        dobRwaAmount = ERC20(address(vault)).balanceOf(address(this)) - before;
    }

    /// @dev Helper: perform a swap with optional hookData
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

    /// @dev Helper: register LP, back asset, and warp past MIN_BACKING_AGE
    function _setupLP(address lp, uint256 deposit, uint256 minPrice, uint16 minPenalty, uint256 maxExp, uint256 alloc)
        internal
    {
        vm.prank(lp);
        lpRegistry.register(deposit);

        vm.prank(lp);
        lpRegistry.backAsset(address(rwaToken), minPrice, minPenalty, maxExp, alloc);

        // Warp past MIN_BACKING_AGE so LP is eligible for fills
        vm.warp(block.timestamp + 1 hours + 1);

        // Re-set oracle price to avoid staleness after warp
        registry.setPrice(address(rwaToken), RWA_PRICE);
    }

    function testLiquidationFilledByLP() public {
        // --- Setup LP ---
        _setupLP(LP1, 100_000e18, 80_000e18, 1500, 200_000e18, 50_000e18);

        // --- Deposit RWA to get dobRWA ---
        _depositRwa(1e18); // 100,000 dobRWA

        uint256 swapAmount = 10_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));

        // Swap with liquidation hookData
        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        uint256 usdcAfter = usdcToken.balanceOf(address(this));

        // Seller should receive 80% (20% penalty) — full amount unaffected by LP fee
        uint256 expectedUsdc = (swapAmount * 8000) / 10000; // 8,000 USDC
        assertEq(usdcAfter - usdcBefore, expectedUsdc, "Seller USDC incorrect");

        // LP should have dobRWA owed
        // LP's raw fill = 8,000 USDC (before fee)
        // dobRWA = 8000 * 10000 / 8000 = 10,000
        uint256 expectedDobRwa = (expectedUsdc * 10000) / (10000 - 2000);
        assertEq(lpRegistry.dobRwaOwed(LP1), expectedDobRwa, "LP dobRWA owed incorrect");

        // LP's backing state: usdcUsed = 8,000 (full amount including fee)
        DobLPRegistry.AssetBacking memory backing = lpRegistry.getBacking(LP1, address(rwaToken));
        assertEq(backing.usdcUsed, expectedUsdc, "LP usdcUsed incorrect");
        assertEq(backing.currentExposure, expectedDobRwa, "LP exposure incorrect");

        // Protocol fee: 1.5% of 8,000 = 120 USDC
        uint256 expectedFee = (expectedUsdc * 150) / 10000;
        assertEq(lpRegistry.accumulatedFees(), expectedFee, "Protocol fee incorrect");
    }

    function testLiquidationPartialLPFill() public {
        // LP only allocates 4,000 USDC — can't cover full 8,000
        _setupLP(LP1, 10_000e18, 0, 0, 200_000e18, 4_000e18);

        _depositRwa(1e18);

        uint256 swapAmount = 10_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 hookUsdcBefore = usdcToken.balanceOf(address(hook));

        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        uint256 hookUsdcAfter = usdcToken.balanceOf(address(hook));

        // Seller still gets full 8,000 USDC
        uint256 expectedUsdc = (swapAmount * 8000) / 10000;
        assertEq(usdcAfter - usdcBefore, expectedUsdc, "Seller should get full amount");

        // LP used 4,000 USDC from allocation (including 1.5% fee)
        DobLPRegistry.AssetBacking memory backing = lpRegistry.getBacking(LP1, address(rwaToken));
        assertEq(backing.usdcUsed, 4_000e18, "LP should have used 4,000 USDC");

        // LP sends 4,000 - 1.5% fee = 3,940 to hook; protocol covers 8,000 - 3,940 = 4,060
        uint256 fee = (4_000e18 * 150) / 10000; // 60 USDC fee
        uint256 lpToHook = 4_000e18 - fee;
        uint256 protocolPortion = expectedUsdc - lpToHook;
        assertEq(hookUsdcBefore - hookUsdcAfter, protocolPortion, "Protocol reserves should cover remainder");
        assertEq(lpRegistry.accumulatedFees(), fee, "Fee should be accumulated");
    }

    function testLiquidationNoWillingLP() public {
        // LP's minOraclePrice is higher than current price
        _setupLP(LP1, 50_000e18, 200_000e18, 0, 200_000e18, 30_000e18);

        _depositRwa(1e18);

        uint256 swapAmount = 10_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 hookUsdcBefore = usdcToken.balanceOf(address(hook));

        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        uint256 hookUsdcAfter = usdcToken.balanceOf(address(hook));

        // Seller still gets 8,000 USDC
        uint256 expectedUsdc = (swapAmount * 8000) / 10000;
        assertEq(usdcAfter - usdcBefore, expectedUsdc, "Seller should still get USDC");

        // No LP fill — LP owed nothing
        assertEq(lpRegistry.dobRwaOwed(LP1), 0, "LP should have no fill");

        // Protocol covers 100%
        assertEq(hookUsdcBefore - hookUsdcAfter, expectedUsdc, "Protocol should cover 100%");
    }

    function testLiquidationLPPenaltyTooLow() public {
        // LP wants ≥25% discount, but only 20% is offered
        _setupLP(LP1, 50_000e18, 0, 2500, 200_000e18, 30_000e18);

        _depositRwa(1e18);

        uint256 swapAmount = 10_000e18;
        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        // LP should not be filled (penalty 20% < required 25%)
        assertEq(lpRegistry.dobRwaOwed(LP1), 0, "LP should not be filled");
    }

    function testLiquidationMultipleLPs() public {
        // Register both LPs before warping
        vm.prank(LP1);
        lpRegistry.register(50_000e18);
        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 500_000e18, 20_000e18);

        vm.prank(LP2);
        lpRegistry.register(50_000e18);
        vm.prank(LP2);
        lpRegistry.backAsset(address(rwaToken), 0, 1500, 500_000e18, 30_000e18);

        // Warp past MIN_BACKING_AGE for both
        vm.warp(block.timestamp + 1 hours + 1);
        registry.setPrice(address(rwaToken), RWA_PRICE);

        _depositRwa(2e18); // 200,000 dobRWA

        uint256 swapAmount = 50_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));

        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        uint256 usdcAfter = usdcToken.balanceOf(address(this));

        // Seller gets 40,000 USDC (50k * 80%)
        uint256 expectedUsdc = (swapAmount * 8000) / 10000;
        assertEq(usdcAfter - usdcBefore, expectedUsdc, "Seller USDC incorrect");

        // LP1 fills first (FIFO): 20,000 raw USDC (full allocation)
        DobLPRegistry.AssetBacking memory backing1 = lpRegistry.getBacking(LP1, address(rwaToken));
        assertEq(backing1.usdcUsed, 20_000e18, "LP1 should use full 20k allocation");

        // LP1 fee: 1.5% of 20,000 = 300 USDC → 19,700 to hook
        // Remaining for LP2: 40,000 - 19,700 = 20,300 USDC needed
        uint256 lp1Fee = (20_000e18 * 150) / 10000;
        uint256 lp2Expected = expectedUsdc - (20_000e18 - lp1Fee);
        DobLPRegistry.AssetBacking memory backing2 = lpRegistry.getBacking(LP2, address(rwaToken));
        assertEq(backing2.usdcUsed, lp2Expected, "LP2 should fill the remainder");
    }

    function testLPMaxExposureRespected() public {
        // LP caps exposure at 5,000 dobRWA
        _setupLP(LP1, 50_000e18, 0, 0, 5_000e18, 30_000e18);

        _depositRwa(1e18);

        uint256 swapAmount = 10_000e18; // would give LP 10,000 dobRWA
        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        DobLPRegistry.AssetBacking memory backing = lpRegistry.getBacking(LP1, address(rwaToken));
        assertEq(backing.currentExposure, 5_000e18, "Exposure should be capped at 5k");
        // LP should fill: 5000 * (10000 - 2000) / 10000 = 4,000 USDC
        assertEq(backing.usdcUsed, 4_000e18, "USDC used should match capped exposure");
    }

    function testAntiFlashLoanProtection() public {
        // Register LP but DON'T warp past MIN_BACKING_AGE
        vm.prank(LP1);
        lpRegistry.register(50_000e18);
        vm.prank(LP1);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 200_000e18, 30_000e18);

        // No warp — LP just registered

        _depositRwa(1e18);

        uint256 swapAmount = 10_000e18;
        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        // LP should NOT be filled (too new)
        assertEq(lpRegistry.dobRwaOwed(LP1), 0, "New LP should not be filled");
    }

    function testNormalSwapUnaffectedByLPSystem() public {
        _setupLP(LP1, 50_000e18, 0, 0, 200_000e18, 30_000e18);

        _depositRwa(1e18);

        uint256 swapAmount = 5_000e18;
        uint256 usdcBefore = usdcToken.balanceOf(address(this));

        // Swap WITHOUT hookData — normal 1:1 peg, LP system not involved
        _swapDobRwaToUsdc(swapAmount, Constants.ZERO_BYTES);

        uint256 usdcAfter = usdcToken.balanceOf(address(this));

        // Full 1:1 swap
        assertEq(usdcAfter - usdcBefore, swapAmount, "Normal swap should be 1:1");

        // LP should have no fills
        assertEq(lpRegistry.dobRwaOwed(LP1), 0, "LP should have no fills on normal swap");
    }

    /*//////////////////////////////////////////////////////////////
                     LP DOBRWA CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function testLPClaimDobRwa() public {
        _setupLP(LP1, 100_000e18, 0, 0, 200_000e18, 50_000e18);

        _depositRwa(1e18);

        uint256 swapAmount = 10_000e18;
        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        uint256 owed = lpRegistry.dobRwaOwed(LP1);
        assertTrue(owed > 0, "LP should have dobRWA owed");

        uint256 dobRwaBefore = ERC20(address(vault)).balanceOf(LP1);

        // LP claims their dobRWA
        vm.prank(LP1);
        lpRegistry.claimDobRwa(owed);

        uint256 dobRwaAfter = ERC20(address(vault)).balanceOf(LP1);
        assertEq(dobRwaAfter - dobRwaBefore, owed, "LP should receive dobRWA");
        assertEq(lpRegistry.dobRwaOwed(LP1), 0, "Owed should be zero after claim");
        assertEq(hook.totalLpDobRwaOwed(), 0, "Hook LP owed should be zero");
    }

    function testRevertClaimMoreThanOwed() public {
        _setupLP(LP1, 100_000e18, 0, 0, 200_000e18, 50_000e18);

        _depositRwa(1e18);

        uint256 swapAmount = 10_000e18;
        _swapDobRwaToUsdc(swapAmount, abi.encode(address(rwaToken)));

        uint256 owed = lpRegistry.dobRwaOwed(LP1);

        vm.prank(LP1);
        vm.expectRevert(DobLPRegistry.InsufficientClaimable.selector);
        lpRegistry.claimDobRwa(owed + 1);
    }

    /*//////////////////////////////////////////////////////////////
                     ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function testProtocolFeeWithdrawal() public {
        _setupLP(LP1, 100_000e18, 0, 0, 200_000e18, 50_000e18);
        _depositRwa(1e18);

        _swapDobRwaToUsdc(10_000e18, abi.encode(address(rwaToken)));

        uint256 fees = lpRegistry.accumulatedFees();
        assertTrue(fees > 0, "Should have fees");

        address treasury = address(0x7777);
        lpRegistry.setProtocolTreasury(treasury);

        uint256 treasuryBefore = usdcToken.balanceOf(treasury);
        lpRegistry.withdrawFees();
        uint256 treasuryAfter = usdcToken.balanceOf(treasury);

        assertEq(treasuryAfter - treasuryBefore, fees, "Treasury should receive fees");
        assertEq(lpRegistry.accumulatedFees(), 0, "Fees should be zero after withdrawal");
    }

    function testOnlyHookCanCallQueryAndFill() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DobLPRegistry.OnlyHook.selector);
        lpRegistry.queryAndFill(address(rwaToken), RWA_PRICE, 2000, 1000e18);
    }

    function testOnlyAdminCanSetLPRegistry() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DobPegHook.OnlyAdmin.selector);
        hook.setLPRegistry(address(0x1234));
    }

    function testOnlyLPRegistryCanReleaseDobRwa() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DobPegHook.OnlyLPRegistry.selector);
        hook.releaseDobRwa(address(0xdead), 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetAssetLiquidity() public {
        _setupLP(LP1, 50_000e18, 0, 0, 200_000e18, 20_000e18);

        vm.prank(LP2);
        lpRegistry.register(30_000e18);
        vm.prank(LP2);
        lpRegistry.backAsset(address(rwaToken), 0, 0, 200_000e18, 15_000e18);

        uint256 liquidity = lpRegistry.getAssetLiquidity(address(rwaToken));
        assertEq(liquidity, 35_000e18, "Total liquidity should be 35k");
    }

    function testSimulateFill() public {
        _setupLP(LP1, 50_000e18, 0, 0, 200_000e18, 20_000e18);

        (uint256 fillable, uint256 dobRwa) =
            lpRegistry.simulateFill(address(rwaToken), RWA_PRICE, 2000, 8_000e18);

        // LP fills 8,000 raw but 1.5% fee means 8000 - 120 = 7,880 goes to hook
        // Need enough raw fill to produce 8,000 to hook — but simulate just processes what's available
        // First LP iteration: fillUsdc = 8000 (matches remaining), fee = 120, usdcToHook = 7880
        // remaining becomes 8000 - 7880 = 120, so it loops again if possible
        // But LP1 already contributed, availableUsdc = 20000 - 8000 = 12000
        // Second pass: fillUsdc = 120, which is > 0 but... wait, the loop index already passed LP1
        // Actually no, the for loop continues from i=1, so only LP1 is checked once
        // So fillable = 7,880 (not quite enough due to fee)
        uint256 expectedFee = (8_000e18 * 150) / 10000; // 120 USDC
        assertEq(fillable, 8_000e18 - expectedFee, "Should account for 1.5% fee");
        assertEq(dobRwa, 10_000e18, "LP should get 10k dobRWA at 20% discount");
    }
}
