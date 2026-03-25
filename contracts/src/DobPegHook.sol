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
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {DobRwaVault} from "./DobRwaVault.sol";
import {DobValidatorRegistry} from "./DobValidatorRegistry.sol";
import {DobLPRegistry} from "./DobLPRegistry.sol";

/// @title DobPegHook
/// @notice Uniswap V4 Hook that uses Custom Accounting (NoOp swap) to execute
///         dobRWA <> USDC swaps at an exact 1:1 oracle-pegged price, with
///         support for liquidation mode, permissionless USDC LP pool with fees,
///         and RWA token rewards for liquidation LPs.
contract DobPegHook is BaseHook, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Dobprotocol RWA Vault (also the dobRWA ERC-20 token).
    DobRwaVault public immutable vault;

    /// @notice Admin address (allowed to initialize pools and seed liquidity).
    address public admin;

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

    // ── Permissionless USDC LP Pool ──

    /// @notice Total USDC value in the LP pool (grows with fees).
    uint256 public totalLpUsdc;

    /// @notice Total outstanding LP shares.
    uint256 public totalShares;

    /// @notice LP address => share balance.
    mapping(address => uint256) public lpShares;

    /// @notice LP address => deposit timestamp (for MIN_LP_DURATION).
    mapping(address => uint48) public lpDepositedAt;

    /// @notice Swap fee in basis points (e.g. 30 = 0.3%). Applied on sell (dUSDC->USDC).
    ///         Accrues to the LP pool.
    uint16 public swapFeeBps;

    /// @notice Protocol fee in basis points (e.g. 10 = 0.1%). Applied on sells.
    ///         Accrues to protocolReserveUsdc (withdrawable by admin).
    uint16 public protocolFeeBps;

    /// @notice Protocol-seeded USDC reserves (separate from LP pool).
    uint256 public protocolReserveUsdc;

    /// @notice Minimum time an LP must wait before withdrawing.
    uint48 public constant MIN_LP_DURATION = 1 hours;

    /// @notice Dead shares minted on first deposit to prevent first-depositor attack.
    uint256 private constant DEAD_SHARES = 1000;

    /// @notice Maximum sellers per RWA token in the resale market.
    uint8 public constant MAX_RWA_SELLERS = 50;

    // ── RWA Resale Market ──

    /// @notice seller → rwaToken → amount of RWA listed for sale.
    mapping(address => mapping(address => uint256)) public rwaForSale;

    /// @notice rwaToken → ordered list of sellers (FIFO).
    mapping(address => address[]) internal _rwaSellers;

    /// @dev rwaToken → seller → index in _rwaSellers.
    mapping(address => mapping(address => uint256)) internal _sellerIndex;

    /// @dev rwaToken → seller → is in the sellers array.
    mapping(address => mapping(address => bool)) internal _isSeller;

    /// @notice rwaToken → total RWA amount listed for sale.
    mapping(address => uint256) public totalRwaListed;

    /// @notice rwaToken → LP-only mode (no dUSDC protection, sells only via LP fills).
    mapping(address => bool) public lpOnlyMode;

    /// @notice Emergency pause flag — blocks swaps, deposits, listings.
    bool public paused;

    /// @dev Transient operation type for unlockCallback multiplexing.
    ///      1 = LP RWA release, 2 = USDC claim redemption.
    uint8 private _unlockOp;

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
        uint256 penaltyLocked
    );

    event LPRegistrySet(address indexed lpRegistry);
    event RwaTokensReleased(address indexed to, address indexed rwaToken, uint256 dobRwaAmount);
    event LPFill(uint256 lpUsdcFilled, uint256 lpDobRwaOwed, uint256 protocolUsdcUsed);
    event UsdcDeposited(address indexed lp, uint256 amount, uint256 shares);
    event UsdcWithdrawn(address indexed lp, uint256 shares, uint256 amount);
    event SwapFeeSet(uint16 feeBps);
    event ProtocolReserveWithdrawn(address indexed to, uint256 amount);
    event RwaListed(address indexed seller, address indexed rwaToken, uint256 amount);
    event RwaDelisted(address indexed seller, address indexed rwaToken, uint256 amount);
    event RwaSold(address indexed buyer, address indexed seller, address indexed rwaToken, uint256 rwaAmount, uint256 usdcAmount);
    event RwaPurchased(address indexed buyer, address indexed rwaToken, uint256 rwaAmount, uint256 usdcCost, uint256 fee);
    event LpOnlyModeSet(address indexed rwaToken, bool enabled);
    event ProtocolFeeSet(uint16 feeBps);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event UsdcClaimsRedeemed(uint256 amount);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyAdmin();
    error InsufficientUsdcReserves();
    error InsufficientLiquidity();
    error LiquidationCapExceeded();
    error GlobalLiquidationCapExceeded();
    error OnlyLPRegistry();
    error ExceedsLPAllocation();
    error ZeroAmount();
    error FeeTooHigh();
    error LPDurationNotMet();
    error InsufficientShares();
    error OracleStale();
    error InsufficientListedRwa();
    error NoListingsAvailable();
    error TokenNotApproved();
    error TooManySellers();
    error ContractPaused();
    error ZeroAddress();
    error SlippageExceeded();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

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
                          ADMIN MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer admin role to a new address.
    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Pause the contract. Blocks swaps, deposits, and listings.
    function pause() external {
        if (msg.sender != admin) revert OnlyAdmin();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the contract.
    function unpause() external {
        if (msg.sender != admin) revert OnlyAdmin();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                           HOOK CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function _beforeInitialize(address sender, PoolKey calldata, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != admin) revert OnlyAdmin();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (sender != admin) revert OnlyAdmin();
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev Core NoOp swap logic with fee on sell direction (dobRWA->USDC).
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (paused) revert ContractPaused();
        require(params.amountSpecified < 0, "Only exact-input swaps supported");

        uint256 amountIn = uint256(-params.amountSpecified);

        Currency inputCurrency;
        Currency outputCurrency;

        if (params.zeroForOne) {
            inputCurrency = key.currency0;
            outputCurrency = key.currency1;
        } else {
            inputCurrency = key.currency1;
            outputCurrency = key.currency0;
        }

        bool isDobRwaToUsdc = Currency.unwrap(inputCurrency) == address(dobRwa);

        uint256 amountOut;
        uint256 penaltyAmount;
        uint256 minAmountOut;

        // ── Parse hookData: extract rwaToken and optional minAmountOut ──
        address rwaToken;
        if (isDobRwaToUsdc && hookData.length >= 64) {
            (rwaToken, minAmountOut) = abi.decode(hookData, (address, uint256));
        } else if (isDobRwaToUsdc && hookData.length >= 32) {
            rwaToken = abi.decode(hookData, (address));
        }

        if (isDobRwaToUsdc && rwaToken != address(0)) {
            (bool enabled, uint16 penaltyBps, uint256 cap, uint256 liquidatedAmount) =
                registry.getLiquidationParams(rwaToken);

            if (enabled) {
                // ── Liquidation path (protocol-mandated penalty) ──
                if (liquidatedAmount + amountIn > cap) revert LiquidationCapExceeded();

                uint256 globalCap = registry.globalLiquidationCap();
                if (globalCap > 0) {
                    uint256 globalLiquidated = registry.globalLiquidatedAmount();
                    if (globalLiquidated + amountIn > globalCap) revert GlobalLiquidationCapExceeded();
                }

                amountOut = (amountIn * (10000 - penaltyBps)) / 10000;
                penaltyAmount = amountIn - amountOut;

                registry.recordLiquidation(rwaToken, amountIn);

                if (address(lpRegistry) != address(0)) {
                    (uint256 oraclePrice, uint48 oracleUpdatedAt) = registry.getPrice(rwaToken);
                    if (block.timestamp - oracleUpdatedAt > vault.maxOracleDelay()) revert OracleStale();
                    (uint256 lpFilled, uint256 lpDobRwa) = lpRegistry.queryAndFill(
                        rwaToken, oraclePrice, penaltyBps, amountOut
                    );
                    if (lpDobRwa > 0) {
                        totalLpDobRwaOwed += lpDobRwa;
                    }
                    emit LPFill(lpFilled, lpDobRwa, amountOut - lpFilled);
                }

                emit LiquidationSwap(sender, rwaToken, amountIn, amountOut, penaltyAmount);
            } else {
                amountOut = _handleNormalSell(rwaToken, amountIn);
            }
        } else if (isDobRwaToUsdc) {
            // No rwaToken: simple sell without LP routing
            amountOut = _handleNormalSell(address(0), amountIn);
        } else {
            // Buy direction: 1:1 peg
            amountOut = amountIn;
        }

        // ── Protocol fee on ALL sells (normal + liquidation) ──
        if (isDobRwaToUsdc && protocolFeeBps > 0) {
            uint256 pFee = (amountOut * protocolFeeBps) / 10000;
            amountOut -= pFee;
            protocolReserveUsdc += pFee;
        }

        // ── Slippage protection ──
        if (minAmountOut > 0 && amountOut < minAmountOut) revert SlippageExceeded();

        // ── 1. SETTLE output tokens (hook -> PoolManager) ──
        ERC20 outputToken = ERC20(Currency.unwrap(outputCurrency));
        poolManager.sync(outputCurrency);
        outputToken.safeTransfer(address(poolManager), amountOut);
        poolManager.settle();

        // ── 2. MINT ERC6909 claims for the input currency ──
        poolManager.mint(address(this), inputCurrency.toId(), amountIn);

        if (penaltyAmount == 0) {
            emit PegSwap(
                sender,
                isDobRwaToUsdc,
                amountIn,
                amountOut
            );
        }

        BeforeSwapDelta delta = toBeforeSwapDelta(
            int128(int256(amountIn)),
            -int128(int256(amountOut))
        );

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    /// @dev Normal sell path: applies swap fee, routes to LPs FIRST (principal
    ///      investors earn discounts), hook reserves cover any remainder.
    ///
    ///      Priority order:
    ///        1. LP fills (principal investors who backed this asset)
    ///        2. Hook USDC reserves (protocol safety net)
    ///
    ///      LP-only mode skips step 2 entirely — protects dUSDC backing.
    function _handleNormalSell(address rwaToken, uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 fee = swapFeeBps > 0 ? (amountIn * swapFeeBps) / 10000 : 0;
        uint256 idealOut = amountIn - fee;
        if (fee > 0) totalLpUsdc += fee;

        // Guard: lpOnlyMode requires an LP registry
        if (lpOnlyMode[rwaToken] && address(lpRegistry) == address(0)) revert InsufficientLiquidity();

        if (address(lpRegistry) != address(0) && rwaToken != address(0)) {
            // ── LP-FIRST: principal investors fill sells and earn their discount ──
            // Protect LP pool: only non-LP USDC is available for sell coverage
            uint256 availableForSells = usdc.balanceOf(address(this)) - totalLpUsdc;

            (uint256 oraclePrice, uint48 updatedAt) = registry.getPrice(rwaToken);
            if (block.timestamp - updatedAt > vault.maxOracleDelay()) revert OracleStale();

            (uint256 lpFilled, uint256 lpDobRwa) = lpRegistry.queryAndFillAtMarket(
                rwaToken, oraclePrice, idealOut
            );
            if (lpDobRwa > 0) totalLpDobRwaOwed += lpDobRwa;

            if (lpOnlyMode[rwaToken]) {
                // LP-only: no hook reserves allowed, LP must cover everything
                if (lpFilled == 0) revert InsufficientLiquidity();
                amountOut = lpFilled;
            } else {
                // Hook reserves cover whatever LPs didn't fill (LP pool is protected)
                uint256 remainder = idealOut > lpFilled ? idealOut - lpFilled : 0;
                if (remainder > availableForSells) revert InsufficientLiquidity();
                amountOut = idealOut;
            }

            emit LPFill(lpFilled, lpDobRwa, idealOut > lpFilled ? idealOut - lpFilled : 0);
        } else {
            // ── No LPs available: hook reserves only (LP pool is protected) ──
            uint256 availableForSells = usdc.balanceOf(address(this)) - totalLpUsdc;
            if (availableForSells < idealOut) revert InsufficientLiquidity();
            amountOut = idealOut;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         RESERVE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Seed the hook with protocol USDC reserves (no LP shares issued).
    function seedUsdc(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        protocolReserveUsdc += amount;
    }

    /// @notice Withdraw protocol reserve USDC. Only callable by admin.
    ///         Cannot withdraw USDC that belongs to the LP pool.
    function withdrawProtocolReserve(uint256 amount) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (amount == 0) revert ZeroAmount();
        if (amount > protocolReserveUsdc) revert InsufficientUsdcReserves();
        // Protect LP pool: only withdraw from non-LP portion
        uint256 availableForWithdraw = usdc.balanceOf(address(this)) - totalLpUsdc;
        if (amount > availableForWithdraw) revert InsufficientUsdcReserves();

        protocolReserveUsdc -= amount;
        usdc.safeTransfer(admin, amount);

        emit ProtocolReserveWithdrawn(admin, amount);
    }

    /// @notice Redeem ERC6909 USDC claims (accumulated from buys) back to real USDC.
    ///         Replenishes hook reserves so sells can be covered.
    function redeemUsdcClaims(uint256 amount) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (amount == 0) revert ZeroAmount();

        _unlockOp = 2;
        poolManager.unlock(abi.encode(amount));
        _unlockOp = 0;

        protocolReserveUsdc += amount;

        emit UsdcClaimsRedeemed(amount);
    }

    /// @notice Check the hook's ERC6909 USDC claim balance in the PoolManager.
    function usdcClaimBalance() external view returns (uint256) {
        return poolManager.balanceOf(address(this), CurrencyLibrary.toId(Currency.wrap(address(usdc))));
    }

    /// @notice Check the hook's total USDC balance.
    function usdcReserves() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                    PERMISSIONLESS USDC LP POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the swap fee. Only callable by admin. Max 10%.
    function setSwapFee(uint16 feeBps) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (feeBps > 1000) revert FeeTooHigh();
        swapFeeBps = feeBps;
        emit SwapFeeSet(feeBps);
    }

    /// @notice Set the protocol fee (on sells). Max 5%. Accrues to protocolReserveUsdc.
    function setProtocolFee(uint16 feeBps) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (feeBps > 500) revert FeeTooHigh();
        protocolFeeBps = feeBps;
        emit ProtocolFeeSet(feeBps);
    }

    /// @notice Deposit USDC into the LP pool and receive shares.
    function depositUsdc(uint256 amount) external returns (uint256 shares) {
        if (paused) revert ContractPaused();
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (totalShares == 0) {
            // First deposit: mint dead shares to prevent first-depositor attack
            require(amount > DEAD_SHARES, "First deposit too small");
            shares = amount - DEAD_SHARES;
            totalShares = amount;
            lpShares[address(1)] += DEAD_SHARES; // dead shares
        } else {
            shares = (amount * totalShares) / totalLpUsdc;
            totalShares += shares;
        }

        totalLpUsdc += amount;
        lpShares[msg.sender] += shares;
        lpDepositedAt[msg.sender] = uint48(block.timestamp);

        emit UsdcDeposited(msg.sender, amount, shares);
    }

    /// @notice Withdraw USDC from the LP pool by burning shares.
    function withdrawUsdc(uint256 shares) external returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        if (lpShares[msg.sender] < shares) revert InsufficientShares();
        if (block.timestamp < lpDepositedAt[msg.sender] + MIN_LP_DURATION) revert LPDurationNotMet();

        amount = (shares * totalLpUsdc) / totalShares;

        // Check actual USDC availability
        uint256 available = usdc.balanceOf(address(this));
        if (amount > available) revert InsufficientUsdcReserves();

        lpShares[msg.sender] -= shares;
        totalShares -= shares;
        totalLpUsdc -= amount;

        usdc.safeTransfer(msg.sender, amount);

        emit UsdcWithdrawn(msg.sender, shares, amount);
    }

    /// @notice Get the current price per share (18-decimal).
    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalLpUsdc * 1e18) / totalShares;
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

    /// @notice Enable or disable LP-only mode for an RWA token.
    ///         When enabled, sells skip hook USDC reserves and only fill from LPs.
    function setLpOnlyMode(address rwaToken, bool enabled) external {
        if (msg.sender != admin) revert OnlyAdmin();
        lpOnlyMode[rwaToken] = enabled;
        emit LpOnlyModeSet(rwaToken, enabled);
    }

    /// @notice Release RWA tokens to an LP by burning ERC6909 claims,
    ///         converting dobRWA to RWA tokens via the vault.
    ///         Only callable by the LP Registry.
    function releaseRwaTokens(address to, address rwaToken, uint256 dobRwaAmount) external {
        if (msg.sender != address(lpRegistry)) revert OnlyLPRegistry();
        if (dobRwaAmount > totalLpDobRwaOwed) revert ExceedsLPAllocation();

        totalLpDobRwaOwed -= dobRwaAmount;

        // Initiate PoolManager unlock to burn ERC6909 claims, take dobRWA,
        // then route through vault.withdraw() to give LP the underlying RWA tokens
        _unlockOp = 1;
        poolManager.unlock(abi.encode(to, rwaToken, dobRwaAmount));
        _unlockOp = 0;

        emit RwaTokensReleased(to, rwaToken, dobRwaAmount);
    }

    /// @notice Callback from PoolManager during unlock sessions.
    ///         Dispatches based on _unlockOp:
    ///         1 = LP RWA token release (burn dobRWA claims → withdraw RWA from vault)
    ///         2 = USDC claim redemption (burn USDC claims → take real USDC to hook)
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (_unlockOp == 1) {
            // ── LP RWA Release ──
            (address to, address rwaToken, uint256 dobRwaAmount) =
                abi.decode(data, (address, address, uint256));

            Currency dobRwaCurrency = Currency.wrap(address(vault));

            // Burn ERC6909 claims (creates positive delta -- hook "pays")
            poolManager.burn(address(this), dobRwaCurrency.toId(), dobRwaAmount);

            // Take underlying dobRWA tokens to this hook (creates negative delta -- cancels out)
            poolManager.take(dobRwaCurrency, address(this), dobRwaAmount);

            // Transfer dobRWA to vault, then call withdraw to convert to RWA tokens for LP
            dobRwa.safeTransfer(address(vault), dobRwaAmount);
            vault.withdraw(rwaToken, dobRwaAmount, to);
        } else if (_unlockOp == 2) {
            // ── USDC Claim Redemption ──
            uint256 amount = abi.decode(data, (uint256));

            Currency usdcCurrency = Currency.wrap(address(usdc));

            // Burn ERC6909 USDC claims (creates positive delta)
            poolManager.burn(address(this), usdcCurrency.toId(), amount);

            // Take actual USDC tokens to hook (creates negative delta -- cancels out)
            poolManager.take(usdcCurrency, address(this), amount);
        }

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                         RWA RESALE MARKET
    //////////////////////////////////////////////////////////////*/

    /// @notice List RWA tokens for sale at oracle price.
    ///         Seller deposits RWA tokens into the hook. Buyers can purchase
    ///         via `buyListedRwa` at the current oracle price.
    /// @param rwaToken The RWA token address to sell.
    /// @param amount   The amount of RWA tokens to list.
    function listRwaForSale(address rwaToken, uint256 amount) external nonReentrant {
        if (paused) revert ContractPaused();
        if (amount == 0) revert ZeroAmount();
        if (!vault.approvedAssets(rwaToken)) revert TokenNotApproved();

        ERC20(rwaToken).safeTransferFrom(msg.sender, address(this), amount);

        if (!_isSeller[rwaToken][msg.sender]) {
            if (_rwaSellers[rwaToken].length >= MAX_RWA_SELLERS) revert TooManySellers();
            _sellerIndex[rwaToken][msg.sender] = _rwaSellers[rwaToken].length;
            _rwaSellers[rwaToken].push(msg.sender);
            _isSeller[rwaToken][msg.sender] = true;
        }

        rwaForSale[msg.sender][rwaToken] += amount;
        totalRwaListed[rwaToken] += amount;

        emit RwaListed(msg.sender, rwaToken, amount);
    }

    /// @notice Delist (withdraw) RWA tokens from the resale market.
    /// @param rwaToken The RWA token address to delist.
    /// @param amount   The amount of RWA tokens to withdraw.
    function delistRwa(address rwaToken, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (rwaForSale[msg.sender][rwaToken] < amount) revert InsufficientListedRwa();

        rwaForSale[msg.sender][rwaToken] -= amount;
        totalRwaListed[rwaToken] -= amount;

        if (rwaForSale[msg.sender][rwaToken] == 0) {
            _removeRwaSeller(rwaToken, msg.sender);
        }

        ERC20(rwaToken).safeTransfer(msg.sender, amount);

        emit RwaDelisted(msg.sender, rwaToken, amount);
    }

    /// @notice Buy listed RWA tokens at oracle price. Buyer pays USDC.
    ///         Fills sellers in FIFO order. Swap fee accrues to the LP pool.
    /// @param rwaToken  The RWA token to buy.
    /// @param rwaAmount The amount of RWA tokens to purchase.
    function buyListedRwa(address rwaToken, uint256 rwaAmount) external nonReentrant {
        if (paused) revert ContractPaused();
        if (rwaAmount == 0) revert ZeroAmount();
        if (totalRwaListed[rwaToken] < rwaAmount) revert NoListingsAvailable();

        // Oracle price + staleness check
        (uint256 priceUsd, uint48 updatedAt) = registry.getPrice(rwaToken);
        if (block.timestamp - updatedAt > vault.maxOracleDelay()) revert OracleStale();

        uint256 usdcCost = (rwaAmount * priceUsd) / 1e18;
        uint256 lpFee = swapFeeBps > 0 ? (usdcCost * swapFeeBps) / 10000 : 0;
        uint256 pFee = protocolFeeBps > 0 ? (usdcCost * protocolFeeBps) / 10000 : 0;

        usdc.safeTransferFrom(msg.sender, address(this), usdcCost + lpFee + pFee);
        if (lpFee > 0) totalLpUsdc += lpFee;
        if (pFee > 0) protocolReserveUsdc += pFee;

        // Fill sellers FIFO and pay them
        _fillRwaSellers(rwaToken, rwaAmount, priceUsd);

        totalRwaListed[rwaToken] -= rwaAmount;
        ERC20(rwaToken).safeTransfer(msg.sender, rwaAmount);

        emit RwaPurchased(msg.sender, rwaToken, rwaAmount, usdcCost, lpFee + pFee);
    }

    /*//////////////////////////////////////////////////////////////
                     RWA RESALE VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the list of sellers for an RWA token.
    function getRwaSellers(address rwaToken) external view returns (address[] memory) {
        return _rwaSellers[rwaToken];
    }

    /// @notice Get the total available RWA listed for sale.
    function getRwaSellersCount(address rwaToken) external view returns (uint256) {
        return _rwaSellers[rwaToken].length;
    }

    /*//////////////////////////////////////////////////////////////
                     RWA RESALE INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Iterate sellers FIFO, deduct amounts, pay USDC, and clean up emptied sellers.
    function _fillRwaSellers(address rwaToken, uint256 rwaAmount, uint256 priceUsd) internal {
        address[] storage sellers = _rwaSellers[rwaToken];
        uint256 remaining = rwaAmount;

        address[] memory toRemove = new address[](sellers.length);
        uint256 removeCount = 0;

        for (uint256 i = 0; i < sellers.length && remaining > 0; i++) {
            address seller = sellers[i];
            uint256 available = rwaForSale[seller][rwaToken];
            if (available == 0) continue;

            uint256 fill = remaining > available ? available : remaining;
            rwaForSale[seller][rwaToken] -= fill;
            remaining -= fill;

            uint256 sellerPayment = (fill * priceUsd) / 1e18;
            usdc.safeTransfer(seller, sellerPayment);

            emit RwaSold(msg.sender, seller, rwaToken, fill, sellerPayment);

            if (rwaForSale[seller][rwaToken] == 0) {
                toRemove[removeCount++] = seller;
            }
        }

        for (uint256 i = 0; i < removeCount; i++) {
            _removeRwaSeller(rwaToken, toRemove[i]);
        }
    }

    /// @dev Remove a seller from the _rwaSellers array using shift-left
    ///      to preserve FIFO order (bounded by MAX_RWA_SELLERS = 50).
    function _removeRwaSeller(address rwaToken, address seller) internal {
        if (!_isSeller[rwaToken][seller]) return;

        uint256 index = _sellerIndex[rwaToken][seller];
        uint256 lastIndex = _rwaSellers[rwaToken].length - 1;

        // Shift elements left to maintain FIFO order
        for (uint256 i = index; i < lastIndex; i++) {
            _rwaSellers[rwaToken][i] = _rwaSellers[rwaToken][i + 1];
            _sellerIndex[rwaToken][_rwaSellers[rwaToken][i]] = i;
        }

        _rwaSellers[rwaToken].pop();
        delete _sellerIndex[rwaToken][seller];
        _isSeller[rwaToken][seller] = false;
    }
}
