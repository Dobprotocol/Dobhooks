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
import {DobPooledLN} from "../src/DobPooledLN.sol";

contract DobPooledLNTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // --- Protocol contracts ---
    DobValidatorRegistry registry;
    DobRwaVault vault;
    DobPegHook hook;
    DobLPRegistry lpRegistry;
    DobPooledLN pooledLN;

    // --- Tokens ---
    MockERC20 rwaToken;
    MockERC20 usdcToken;

    // --- Pool ---
    PoolKey poolKey;
    PoolId poolId;

    // --- Addresses ---
    address constant DEPOSITOR_A = address(0xAAA1);
    address constant DEPOSITOR_B = address(0xBBB2);
    address constant DEPOSITOR_C = address(0xCCC3);

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

        // ───── 4. Deploy hook ─────
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x7777 << 144)
        );
        bytes memory constructorArgs =
            abi.encode(poolManager, vault, usdcToken, registry, address(this));
        deployCodeTo("DobPegHook.sol:DobPegHook", constructorArgs, flags);
        hook = DobPegHook(flags);

        // ───── 5. Deploy LP Registry ─────
        lpRegistry = new DobLPRegistry(address(usdcToken), address(this));
        lpRegistry.setHook(address(hook));
        lpRegistry.setRegistry(address(registry));

        // ───── 6. Authorize hook ─────
        registry.setHook(address(hook));
        vault.setHook(address(hook));
        hook.setLPRegistry(address(lpRegistry));

        // ───── 7. Set up pool ─────
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
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // ───── 8. Token approvals ─────
        ERC20(address(vault)).approve(address(permit2), type(uint256).max);
        ERC20(address(vault)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(vault), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(vault), address(poolManager), type(uint160).max, type(uint48).max);
        usdcToken.approve(address(permit2), type(uint256).max);
        usdcToken.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(usdcToken), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(usdcToken), address(poolManager), type(uint160).max, type(uint48).max);

        // ───── 9. Oracle & Vault setup ─────
        registry.setPrice(address(rwaToken), RWA_PRICE);
        vault.addApprovedAsset(address(rwaToken));
        registry.setLiquidationParams(address(rwaToken), 2000, 500_000e18); // 20% penalty
        registry.setGlobalLiquidationCap(1_000_000e18);

        // ───── 10. Seed hook with USDC ─────
        usdcToken.mint(address(this), 2_000_000e18);
        usdcToken.approve(address(hook), type(uint256).max);
        hook.seedUsdc(500_000e18);

        // ───── 11. Mint RWA tokens ─────
        rwaToken.mint(address(this), 100e18);
        rwaToken.approve(address(vault), type(uint256).max);

        // ───── 12. Deploy DobPooledLN ─────
        pooledLN = new DobPooledLN(
            address(usdcToken),
            address(lpRegistry),
            address(this),  // owner = test contract (Dobprotocol admin)
            100e18           // min deposit = 100 USDC
        );

        // ───── 13. Fund depositors ─────
        usdcToken.mint(DEPOSITOR_A, 500_000e18);
        usdcToken.mint(DEPOSITOR_B, 200_000e18);
        usdcToken.mint(DEPOSITOR_C, 100_000e18);

        vm.prank(DEPOSITOR_A);
        usdcToken.approve(address(pooledLN), type(uint256).max);
        vm.prank(DEPOSITOR_B);
        usdcToken.approve(address(pooledLN), type(uint256).max);
        vm.prank(DEPOSITOR_C);
        usdcToken.approve(address(pooledLN), type(uint256).max);

        // ───── 14. Lower lpRegistry minDeposit for test ─────
        lpRegistry.setMinDeposit(100e18);
        lpRegistry.setMinAllocation(50e18);
    }

    /*//////////////////////////////////////////////////////////////
                         HELPERS
    //////////////////////////////////////////////////////////////*/

    function _depositRwa(uint256 rwaAmount) internal returns (uint256 dobRwaAmount) {
        uint256 before = ERC20(address(vault)).balanceOf(address(this));
        vault.deposit(address(rwaToken), rwaAmount);
        dobRwaAmount = ERC20(address(vault)).balanceOf(address(this)) - before;
    }

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

    /// @dev Setup the pooled LN: depositors fund it, register in registry, back asset.
    function _setupPooledLN() internal {
        // Depositors fund the pool
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);
        vm.prank(DEPOSITOR_B);
        pooledLN.deposit(50_000e18);

        // Register in LP registry with initial capital
        pooledLN.registerInRegistry(100_000e18);

        // Back the RWA token with 5% discount
        pooledLN.backAsset(
            address(rwaToken),
            0,          // minOraclePrice = 0 (accept any)
            500,        // 5% discount (minPenaltyBps)
            500_000e18, // maxExposure
            50_000e18   // USDC allocation
        );

        // Warp past MIN_BACKING_AGE
        vm.warp(block.timestamp + 2 hours);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT / SHARE TESTS
    //////////////////////////////////////////////////////////////*/

    function testDeposit() public {
        vm.prank(DEPOSITOR_A);
        uint256 sharesA = pooledLN.deposit(10_000e18);

        assertGt(sharesA, 0, "Should receive shares");
        assertEq(pooledLN.totalPoolUsdc(), 10_000e18, "Pool USDC tracked");
        assertEq(pooledLN.shares(DEPOSITOR_A), sharesA, "Shares recorded");
    }

    function testMultipleDepositors() public {
        vm.prank(DEPOSITOR_A);
        uint256 sharesA = pooledLN.deposit(10_000e18);

        vm.prank(DEPOSITOR_B);
        uint256 sharesB = pooledLN.deposit(5_000e18);

        // A deposited 2x of B → should have ~2x shares (dead shares cause minor offset on first deposit)
        assertApproxEqRel(sharesA, sharesB * 2, 0.01e18, "Share ratio should reflect deposit ratio");
        assertEq(pooledLN.totalPoolUsdc(), 15_000e18, "Total pool USDC");
    }

    function testDepositRevertBelowMin() public {
        vm.prank(DEPOSITOR_A);
        vm.expectRevert(DobPooledLN.BelowMinDeposit.selector);
        pooledLN.deposit(50e18); // below 100e18 min
    }

    function testDepositRevertWhenPaused() public {
        pooledLN.pause();

        vm.prank(DEPOSITOR_A);
        vm.expectRevert(DobPooledLN.ContractPaused.selector);
        pooledLN.deposit(1_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                     WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function testWithdraw() public {
        vm.prank(DEPOSITOR_A);
        uint256 sharesA = pooledLN.deposit(10_000e18);

        // Warp past MIN_DEPOSIT_DURATION
        vm.warp(block.timestamp + 2 hours);

        uint256 balBefore = usdcToken.balanceOf(DEPOSITOR_A);
        vm.prank(DEPOSITOR_A);
        pooledLN.withdraw(sharesA);
        uint256 balAfter = usdcToken.balanceOf(DEPOSITOR_A);

        // Dead shares cause a tiny rounding loss on first depositor (~1000 wei)
        assertApproxEqRel(balAfter - balBefore, 10_000e18, 0.01e18, "Should withdraw ~full deposit");
        assertEq(pooledLN.shares(DEPOSITOR_A), 0, "Shares should be zero");
    }

    function testWithdrawRevertBeforeDuration() public {
        vm.prank(DEPOSITOR_A);
        uint256 sharesA = pooledLN.deposit(10_000e18);

        vm.prank(DEPOSITOR_A);
        vm.expectRevert(DobPooledLN.DepositDurationNotMet.selector);
        pooledLN.withdraw(sharesA);
    }

    function testWithdrawRevertInsufficientShares() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(10_000e18);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(DEPOSITOR_A);
        vm.expectRevert(DobPooledLN.InsufficientShares.selector);
        pooledLN.withdraw(999_999e18); // more than they have
    }

    /*//////////////////////////////////////////////////////////////
                REGISTER & BACK ASSET TESTS
    //////////////////////////////////////////////////////////////*/

    function testRegisterInRegistry() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(10_000e18);

        pooledLN.registerInRegistry(5_000e18);

        assertTrue(pooledLN.registered(), "Should be registered");
        (uint256 deposited,,, bool active) = lpRegistry.positions(address(pooledLN));
        assertEq(deposited, 5_000e18, "Registry position should be 5k");
        assertTrue(active, "Position should be active");
    }

    function testRegisterRevertAlreadyRegistered() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(10_000e18);

        pooledLN.registerInRegistry(5_000e18);

        vm.expectRevert(DobPooledLN.AlreadyRegistered.selector);
        pooledLN.registerInRegistry(5_000e18);
    }

    function testBackAsset() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);

        pooledLN.registerInRegistry(50_000e18);
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);

        assertTrue(pooledLN.isBackedAsset(address(rwaToken)), "Should be backed");
        assertEq(pooledLN.backedAssetCount(), 1, "One backed asset");

        DobLPRegistry.AssetBacking memory backing = pooledLN.getBacking(address(rwaToken));
        assertTrue(backing.active, "Backing active in registry");
        assertEq(backing.minPenaltyBps, 500, "5% discount");
        assertEq(backing.usdcAllocated, 30_000e18, "30k allocated");
    }

    function testBackAssetRevertNotRegistered() public {
        vm.expectRevert(DobPooledLN.NotRegistered.selector);
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);
    }

    function testAddCapitalToRegistry() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);

        pooledLN.registerInRegistry(30_000e18);
        pooledLN.addCapitalToRegistry(20_000e18);

        (uint256 deposited,,,) = lpRegistry.positions(address(pooledLN));
        assertEq(deposited, 50_000e18, "Should have 50k total in registry");
    }

    function testStopBacking() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);

        pooledLN.registerInRegistry(50_000e18);
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);
        pooledLN.stopBacking(address(rwaToken));

        DobLPRegistry.AssetBacking memory backing = pooledLN.getBacking(address(rwaToken));
        assertFalse(backing.active, "Backing should be stopped");
    }

    /*//////////////////////////////////////////////////////////////
                  DYNAMIC DISCOUNT TESTS
    //////////////////////////////////////////////////////////////*/

    function testUpdateDiscount() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);

        pooledLN.registerInRegistry(50_000e18);
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);

        // Update discount from 5% to 8%
        pooledLN.updateDiscount(address(rwaToken), 800);

        DobLPRegistry.AssetBacking memory backing = pooledLN.getBacking(address(rwaToken));
        assertEq(backing.minPenaltyBps, 800, "Discount should be 8%");
    }

    function testUpdateDiscountMultipleTimes() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);

        pooledLN.registerInRegistry(50_000e18);
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);

        // Simulate dynamic updates (as if from keeper/oracle)
        pooledLN.updateDiscount(address(rwaToken), 300);
        DobLPRegistry.AssetBacking memory b1 = pooledLN.getBacking(address(rwaToken));
        assertEq(b1.minPenaltyBps, 300, "3%");

        pooledLN.updateDiscount(address(rwaToken), 1500);
        DobLPRegistry.AssetBacking memory b2 = pooledLN.getBacking(address(rwaToken));
        assertEq(b2.minPenaltyBps, 1500, "15%");

        pooledLN.updateDiscount(address(rwaToken), 50);
        DobLPRegistry.AssetBacking memory b3 = pooledLN.getBacking(address(rwaToken));
        assertEq(b3.minPenaltyBps, 50, "0.5%");
    }

    function testUpdateConditions() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);

        pooledLN.registerInRegistry(50_000e18);
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);

        pooledLN.updateConditions(address(rwaToken), 50_000e18, 1000, 1_000_000e18);

        DobLPRegistry.AssetBacking memory backing = pooledLN.getBacking(address(rwaToken));
        assertEq(backing.minOraclePrice, 50_000e18, "Min oracle price updated");
        assertEq(backing.minPenaltyBps, 1000, "Discount updated to 10%");
        assertEq(backing.maxExposure, 1_000_000e18, "Max exposure updated");
    }

    function testOnlyOwnerCanUpdateDiscount() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);

        pooledLN.registerInRegistry(50_000e18);
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);

        vm.prank(DEPOSITOR_A);
        vm.expectRevert("UNAUTHORIZED");
        pooledLN.updateDiscount(address(rwaToken), 800);
    }

    /*//////////////////////////////////////////////////////////////
              FILL EXECUTION (END-TO-END)
    //////////////////////////////////////////////////////////////*/

    function testPooledLNReceivesFillFromLiquidation() public {
        _setupPooledLN();

        // Deposit RWA → get dobRWA → liquidation swap
        _depositRwa(1e18); // 100,000 dUSDC

        uint256 swapAmount = 10_000e18;
        bytes memory hookData = abi.encode(address(rwaToken));
        _swapDobRwaToUsdc(swapAmount, hookData);

        // Pooled LN should have RWA owed in the registry
        uint256 rwaOwed = pooledLN.getRwaOwed(address(rwaToken));
        assertGt(rwaOwed, 0, "Pooled LN should have RWA owed from fill");
    }

    function testPooledLNReceivesFillFromSellFallback() public {
        _setupPooledLN();

        // Enable LP-only mode so ALL sells go through LPs
        hook.setLpOnlyMode(address(rwaToken), true);

        // Deposit RWA → get dobRWA
        _depositRwa(1e18);

        // Normal sell with hookData (not liquidation, just LP fallback)
        // Disable liquidation first so it uses normal sell path
        registry.disableLiquidation(address(rwaToken));

        uint256 swapAmount = 1_000e18;
        bytes memory hookData = abi.encode(address(rwaToken));
        _swapDobRwaToUsdc(swapAmount, hookData);

        uint256 rwaOwed = pooledLN.getRwaOwed(address(rwaToken));
        assertGt(rwaOwed, 0, "Pooled LN should earn from sell fallback");
    }

    /*//////////////////////////////////////////////////////////////
              RWA DISTRIBUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testClaimAndDistributeRwa() public {
        _setupPooledLN();

        // Trigger a liquidation fill
        _depositRwa(1e18);
        bytes memory hookData = abi.encode(address(rwaToken));
        _swapDobRwaToUsdc(10_000e18, hookData);

        uint256 rwaOwed = pooledLN.getRwaOwed(address(rwaToken));
        assertGt(rwaOwed, 0, "Should have RWA owed");

        // Claim from registry → RWA tokens land in pooledLN
        pooledLN.claimRwaFromRegistry(address(rwaToken), rwaOwed);

        uint256 rwaBalance = rwaToken.balanceOf(address(pooledLN));
        assertGt(rwaBalance, 0, "Pooled LN should hold RWA tokens");

        // Distribute to depositor A (has 100k/150k = 66.7% of shares)
        pooledLN.distributeRwa(address(rwaToken), DEPOSITOR_A);
        uint256 claimableA = pooledLN.rwaClaimable(DEPOSITOR_A, address(rwaToken));
        assertGt(claimableA, 0, "Depositor A should have claimable RWA");

        // Depositor A withdraws RWA
        uint256 rwaBefore = rwaToken.balanceOf(DEPOSITOR_A);
        vm.prank(DEPOSITOR_A);
        pooledLN.withdrawRwa(address(rwaToken), claimableA);
        uint256 rwaAfter = rwaToken.balanceOf(DEPOSITOR_A);

        assertEq(rwaAfter - rwaBefore, claimableA, "Should receive RWA tokens");
        assertEq(pooledLN.rwaClaimable(DEPOSITOR_A, address(rwaToken)), 0, "Claimable should be 0");
    }

    function testBatchDistributeRwa() public {
        _setupPooledLN();

        // Trigger fill
        _depositRwa(1e18);
        _swapDobRwaToUsdc(10_000e18, abi.encode(address(rwaToken)));

        uint256 rwaOwed = pooledLN.getRwaOwed(address(rwaToken));
        pooledLN.claimRwaFromRegistry(address(rwaToken), rwaOwed);

        // Batch distribute to both depositors
        address[] memory depositors = new address[](2);
        depositors[0] = DEPOSITOR_A;
        depositors[1] = DEPOSITOR_B;
        pooledLN.batchDistributeRwa(address(rwaToken), depositors);

        uint256 claimableA = pooledLN.rwaClaimable(DEPOSITOR_A, address(rwaToken));
        uint256 claimableB = pooledLN.rwaClaimable(DEPOSITOR_B, address(rwaToken));

        assertGt(claimableA, 0, "A should have claimable");
        assertGt(claimableB, 0, "B should have claimable");

        // A deposited 100k, B deposited 50k → A should have 2x B's share
        assertEq(claimableA, claimableB * 2, "A should have 2x of B");
    }

    function testWithdrawRwaRevertInsufficient() public {
        vm.prank(DEPOSITOR_A);
        vm.expectRevert(DobPooledLN.InsufficientRwa.selector);
        pooledLN.withdrawRwa(address(rwaToken), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                  ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function testOnlyOwnerCanBackAsset() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);
        pooledLN.registerInRegistry(50_000e18);

        vm.prank(DEPOSITOR_A);
        vm.expectRevert("UNAUTHORIZED");
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);
    }

    function testOnlyOwnerCanRegister() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(10_000e18);

        vm.prank(DEPOSITOR_A);
        vm.expectRevert("UNAUTHORIZED");
        pooledLN.registerInRegistry(5_000e18);
    }

    function testOnlyOwnerCanClaimRwa() public {
        vm.prank(DEPOSITOR_A);
        vm.expectRevert("UNAUTHORIZED");
        pooledLN.claimRwaFromRegistry(address(rwaToken), 1e18);
    }

    function testOnlyOwnerCanDistributeRwa() public {
        vm.prank(DEPOSITOR_A);
        vm.expectRevert("UNAUTHORIZED");
        pooledLN.distributeRwa(address(rwaToken), DEPOSITOR_A);
    }

    function testOnlyOwnerCanPause() public {
        vm.prank(DEPOSITOR_A);
        vm.expectRevert("UNAUTHORIZED");
        pooledLN.pause();
    }

    /*//////////////////////////////////////////////////////////////
                     VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testSharePrice() public {
        assertEq(pooledLN.sharePrice(), 1e18, "Initial share price = 1");

        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(10_000e18);

        assertEq(pooledLN.sharePrice(), 1e18, "Share price should still be ~1");
    }

    function testIncreaseAllocation() public {
        vm.prank(DEPOSITOR_A);
        pooledLN.deposit(100_000e18);

        pooledLN.registerInRegistry(80_000e18);
        pooledLN.backAsset(address(rwaToken), 0, 500, 500_000e18, 30_000e18);
        pooledLN.increaseAllocation(address(rwaToken), 10_000e18);

        DobLPRegistry.AssetBacking memory backing = pooledLN.getBacking(address(rwaToken));
        assertEq(backing.usdcAllocated, 40_000e18, "Allocation should be 40k");
    }
}
