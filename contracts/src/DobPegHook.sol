// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {DobRwaVault} from "./DobRwaVault.sol";
import {DobValidatorRegistry} from "./DobValidatorRegistry.sol";
import {DobLPRegistry} from "./DobLPRegistry.sol";

/// @title DobPegHook
/// @notice Uniswap V4 Hook that uses Custom Accounting (NoOp swap) to execute
///         dobRWA ↔ USDC swaps at an exact 1:1 oracle-pegged price, with
///         support for liquidation mode — distressed assets swap at a penalty
///         discount, subject to per-asset and global caps.
///
///         When a user swaps dobRWA → USDC:
///           • Normal mode:      user receives exactly `amountIn` USDC (1:1 peg)
///           • Liquidation mode:  user receives `amountIn * (1 - penalty)` USDC;
///                                the penalty portion of dobRWA is burned.
///
///         The hook holds USDC reserves (seeded by the protocol / LPs) which back
///         the instant redemption guarantee.
contract DobPegHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Dobprotocol RWA Vault (also the dobRWA ERC-20 token).
    DobRwaVault public immutable vault;

    /// @notice Admin address (allowed to initialize pools and seed liquidity).
    address public immutable admin;

    /// @notice The USDC token used for settlements.
    ERC20 public immutable usdc;

    /// @notice The dobRWA token (same as vault, typed as ERC20 for transfers).
    ERC20 public immutable dobRwa;

    /// @notice The DobValidatorRegistry for oracle prices and liquidation params.
    DobValidatorRegistry public immutable registry;

    /// @notice The LP Registry for permissionless liquidation fills.
    DobLPRegistry public lpRegistry;

    /// @notice Total dobRWA owed to LPs (safety invariant for claims).
    uint256 public totalLpDobRwaOwed;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PegSwap(
        address indexed user,
        bool dobRwaToUsdc,
        uint256 amountIn,
        uint256 amountOut
    );

    event LiquidationSwap(
        address indexed user,
        address indexed rwaToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 penaltyBurned
    );

    event LPRegistrySet(address indexed lpRegistry);
    event DobRwaReleased(address indexed to, uint256 amount);
    event LPFill(uint256 lpUsdcFilled, uint256 lpDobRwaOwed, uint256 protocolUsdcUsed);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyAdmin();
    error InsufficientUsdcReserves();
    error LiquidationCapExceeded();
    error GlobalLiquidationCapExceeded();
    error OnlyLPRegistry();
    error ExceedsLPAllocation();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _poolManager The Uniswap V4 PoolManager singleton.
    /// @param _vault       The DobRwaVault (also the dobRWA token).
    /// @param _usdc        The USDC token address.
    /// @param _registry    The DobValidatorRegistry address.
    /// @param _admin       The protocol admin.
    constructor(
        IPoolManager _poolManager,
        DobRwaVault _vault,
        ERC20 _usdc,
        DobValidatorRegistry _registry,
        address _admin
    ) BaseHook(_poolManager) {
        vault = _vault;
        usdc = _usdc;
        dobRwa = ERC20(address(_vault));
        registry = _registry;
        admin = _admin;
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,       // Admin-only pool creation
            afterInitialize: false,
            beforeAddLiquidity: true,      // Restrict LP access
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,              // Intercept swap for oracle peg
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,   // Custom accounting (NoOp swap)
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                           HOOK CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Only the admin can initialize a pool with this hook.
    function _beforeInitialize(address sender, PoolKey calldata, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != admin) revert OnlyAdmin();
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Only the admin can add liquidity (simplified LP whitelist).
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (sender != admin) revert OnlyAdmin();
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev Core NoOp swap logic — intercepts any swap and executes at the 1:1 peg,
    ///      or at a penalized rate if the underlying RWA is in liquidation mode.
    ///
    /// V4 Custom Accounting Flow
    /// ─────────────────────────
    /// The `BeforeSwapDelta(+amountIn, -amountOut)` creates hook-level deltas
    /// AFTER `_beforeSwap` returns:
    ///   • input currency:  +amountIn   (PoolManager owes hook)
    ///   • output currency: -amountOut  (hook owes PoolManager)
    ///
    /// To zero these out before `unlock` ends, we proactively create
    /// opposite deltas INSIDE this callback:
    ///   1. SETTLE output tokens (sync→transfer→settle)  → hook delta = +amountOut
    ///      Net after BeforeSwapDelta: +amountOut + (-amountOut) = 0 ✓
    ///   2. MINT ERC6909 claims for input                → hook delta = -amountIn
    ///      Net after BeforeSwapDelta: -amountIn + (+amountIn) = 0 ✓
    ///
    /// The caller's (router's) swapDelta is adjusted by `swapDelta - hookDelta`,
    /// so the swapper still pays the input and receives the output.
    ///
    /// @param hookData If the swap is on a liquidation-mode asset, encode the
    ///                 RWA token address as `abi.encode(rwaTokenAddress)`.
    ///                 Pass empty bytes for normal 1:1 peg swaps.
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // We only support exact-input swaps for simplicity
        require(params.amountSpecified < 0, "Only exact-input swaps supported");

        uint256 amountIn = uint256(-params.amountSpecified);

        // Determine the input/output currencies based on swap direction
        Currency inputCurrency;
        Currency outputCurrency;

        if (params.zeroForOne) {
            inputCurrency = key.currency0;
            outputCurrency = key.currency1;
        } else {
            inputCurrency = key.currency1;
            outputCurrency = key.currency0;
        }

        // Determine if this is a dobRWA → USDC swap (sell direction)
        bool isDobRwaToUsdc = Currency.unwrap(inputCurrency) == address(dobRwa);

        // ── Check for liquidation mode ──
        uint256 amountOut;
        uint256 penaltyAmount;

        if (isDobRwaToUsdc && hookData.length > 0) {
            // Decode the RWA token address from hookData
            address rwaToken = abi.decode(hookData, (address));

            (bool enabled, uint16 penaltyBps, uint256 cap, uint256 liquidatedAmount) =
                registry.getLiquidationParams(rwaToken);

            if (enabled) {
                // ── Liquidation swap ──

                // Check per-asset cap
                if (liquidatedAmount + amountIn > cap) revert LiquidationCapExceeded();

                // Check global cap
                uint256 globalCap = registry.globalLiquidationCap();
                if (globalCap > 0) {
                    uint256 globalLiquidated = registry.globalLiquidatedAmount();
                    if (globalLiquidated + amountIn > globalCap) revert GlobalLiquidationCapExceeded();
                }

                // Apply penalty: amountOut = amountIn * (10000 - penaltyBps) / 10000
                amountOut = (amountIn * (10000 - penaltyBps)) / 10000;
                penaltyAmount = amountIn - amountOut;

                // Record the liquidation in the registry
                registry.recordLiquidation(rwaToken, amountIn);

                // ── Query LP Registry for fills ──
                if (address(lpRegistry) != address(0)) {
                    (uint256 oraclePrice, ) = registry.getPrice(rwaToken);
                    (uint256 lpFilled, uint256 lpDobRwa) = lpRegistry.queryAndFill(
                        rwaToken, oraclePrice, penaltyBps, amountOut
                    );
                    if (lpDobRwa > 0) {
                        totalLpDobRwaOwed += lpDobRwa;
                    }
                    emit LPFill(lpFilled, lpDobRwa, amountOut - lpFilled);
                }

                emit LiquidationSwap(tx.origin, rwaToken, amountIn, amountOut, penaltyAmount);
            } else {
                // Not in liquidation mode — fall through to 1:1 peg
                amountOut = amountIn;
            }
        } else {
            // Normal 1:1 peg swap (or USDC → dobRWA direction)
            amountOut = amountIn;
        }

        // ── 1. SETTLE output tokens (hook → PoolManager) ──
        // Creates hook delta = +amountOut for the output currency.
        // This offsets the -amountOut that BeforeSwapDelta will apply.
        ERC20 outputToken = ERC20(Currency.unwrap(outputCurrency));
        poolManager.sync(outputCurrency);
        outputToken.safeTransfer(address(poolManager), amountOut);
        poolManager.settle();

        // ── 2. MINT ERC6909 claims for the input currency ──
        // Creates hook delta = -amountIn for the input currency.
        // This offsets the +amountIn that BeforeSwapDelta will apply.
        // The hook receives ERC6909 claims redeemable for the actual tokens later.
        //
        // In liquidation mode, the full amountIn is still claimed as ERC6909.
        // The penalty portion (amountIn - amountOut) stays permanently locked
        // as ERC6909 claims in the hook — effectively burned from circulation.
        poolManager.mint(address(this), inputCurrency.toId(), amountIn);

        if (penaltyAmount == 0) {
            emit PegSwap(
                tx.origin,
                isDobRwaToUsdc,
                amountIn,
                amountOut
            );
        }

        // Return the NoOp delta:
        // specifiedDelta > 0 means hook consumed all the specified (input) tokens
        // unspecifiedDelta < 0 means hook is providing the unspecified (output) tokens
        BeforeSwapDelta delta = toBeforeSwapDelta(
            int128(int256(amountIn)),   // hook takes all specified input
            -int128(int256(amountOut))  // hook gives all unspecified output
        );

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         RESERVE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Seed the hook with USDC reserves for redemptions.
    /// @param amount The amount of USDC to deposit.
    function seedUsdc(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Check the hook's USDC reserve balance.
    function usdcReserves() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        LP REGISTRY INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the LP Registry address. Only callable by admin.
    function setLPRegistry(address _lpRegistry) external {
        if (msg.sender != admin) revert OnlyAdmin();
        lpRegistry = DobLPRegistry(_lpRegistry);
        emit LPRegistrySet(_lpRegistry);
    }

    /// @notice Release dobRWA to an LP by burning ERC6909 claims and
    ///         transferring the underlying tokens. Only callable by the LP Registry.
    /// @param to     The LP address to receive dobRWA.
    /// @param amount The amount of dobRWA to release.
    function releaseDobRwa(address to, uint256 amount) external {
        if (msg.sender != address(lpRegistry)) revert OnlyLPRegistry();
        if (amount > totalLpDobRwaOwed) revert ExceedsLPAllocation();

        totalLpDobRwaOwed -= amount;

        // Initiate PoolManager unlock to burn ERC6909 claims and take tokens
        poolManager.unlock(abi.encode(to, amount));

        emit DobRwaReleased(to, amount);
    }

    /// @notice Callback from PoolManager during LP claim unlock session.
    ///         Burns the hook's ERC6909 claims and sends underlying dobRWA to the LP.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));

        Currency dobRwaCurrency = Currency.wrap(address(vault));

        // Burn ERC6909 claims (creates positive delta — hook "pays")
        poolManager.burn(address(this), dobRwaCurrency.toId(), amount);

        // Take underlying tokens to LP (creates negative delta — cancels out)
        poolManager.take(dobRwaCurrency, to, amount);

        return "";
    }
}
