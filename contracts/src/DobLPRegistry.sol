// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

/// @title DobLPRegistry
/// @notice Permissionless LP registry for the Dobprotocol Liquidity Node.
///         LPs deposit USDC and set per-asset conditions under which they are
///         willing to buy discounted dobRWA during liquidation events.
///
///         When a liquidation swap occurs, the DobPegHook calls `queryAndFill`
///         to iterate registered backers, check each LP's conditions against the
///         current oracle price and penalty, and fill willing LPs in FIFO order.
///
///         Security features:
///         - MIN_BACKING_AGE prevents flash-loan LP attacks
///         - Time-locked withdrawals prevent front-run exit before liquidations
///         - MAX_BACKERS_PER_ASSET caps gas cost of on-chain iteration
///         - ReentrancyGuard on all state-modifying token transfers
///         - RESERVE_BPS (33%) locks LP capital during asset distress — released
///           when the asset returns to healthy or after RESERVE_WITHDRAWAL_DELAY
contract DobLPRegistry is Owned, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct LPPosition {
        uint256 usdcDeposited;   // lifetime total deposited (decremented on withdrawal)
        uint256 usdcAvailable;   // not allocated to any asset
        uint48  registeredAt;    // anti-flash-loan timestamp
        bool    active;
    }

    struct AssetBacking {
        uint256 minOraclePrice;  // min oracle price to accept (18-decimal USD)
        uint16  minPenaltyBps;   // min discount required (e.g. 1000 = 10%)
        uint256 maxExposure;     // max dobRWA to accumulate for this asset
        uint256 currentExposure; // running total of dobRWA received
        uint256 usdcAllocated;   // USDC earmarked for this asset
        uint256 usdcUsed;        // USDC already spent on fills
        uint48  backedAt;        // when backing started (anti-frontrun)
        bool    active;
    }

    struct WithdrawalRequest {
        uint256 amount;
        uint48  requestedAt;
    }

    /// @notice Tracks the 33% reserve held when an LP exits a distressed asset.
    struct ReserveHold {
        uint256 amount;          // USDC locked as reserve
        address rwaToken;        // the distressed asset that caused the hold
        uint48  createdAt;       // timestamp for the reserve withdrawal delay
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MIN_DEPOSIT = 100e18;
    uint256 public constant MIN_ALLOCATION = 50e18;
    uint48  public constant WITHDRAWAL_DELAY = 24 hours;
    uint48  public constant MIN_BACKING_AGE = 1 hours;
    uint8   public constant MAX_BACKERS_PER_ASSET = 50;
    uint16  public constant PROTOCOL_FEE_BPS = 150; // 1.5% fee on LP fills
    uint16  public constant RESERVE_BPS = 3300;      // 33% reserve on distressed exit
    uint48  public constant RESERVE_WITHDRAWAL_DELAY = 7 days;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    ERC20 public immutable usdc;
    IDobValidatorRegistryLP public registry;
    address public hook;

    /// @notice Protocol treasury address that receives fees from LP fills.
    address public protocolTreasury;

    /// @notice Accumulated protocol fees (withdrawable by owner).
    uint256 public accumulatedFees;

    mapping(address => LPPosition) public positions;
    mapping(address lp => mapping(address asset => AssetBacking)) public backings;

    /// @dev asset -> ordered list of LP addresses backing it
    mapping(address => address[]) internal _assetBackers;
    /// @dev asset -> LP -> index in _assetBackers (for O(1) removal)
    mapping(address => mapping(address => uint256)) internal _backerIndex;

    mapping(address => WithdrawalRequest) public withdrawalRequests;

    /// @dev LP -> array of reserve holds from distressed asset exits
    mapping(address => ReserveHold[]) public reserveHolds;

    /// @dev RWA tokens owed to each LP per asset (accumulated from fills, claimable via hook)
    /// lp => rwaToken => dobRwaAmount
    mapping(address => mapping(address => uint256)) public rwaOwed;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event LPRegistered(address indexed lp, uint256 amount);
    event LPDeposited(address indexed lp, uint256 amount);
    event AssetBacked(
        address indexed lp,
        address indexed rwaToken,
        uint256 minOraclePrice,
        uint16  minPenaltyBps,
        uint256 maxExposure,
        uint256 usdcAllocated
    );
    event ConditionsUpdated(
        address indexed lp,
        address indexed rwaToken,
        uint256 minOraclePrice,
        uint16  minPenaltyBps,
        uint256 maxExposure
    );
    event AllocationIncreased(address indexed lp, address indexed rwaToken, uint256 amount);
    event BackingStopped(address indexed lp, address indexed rwaToken, uint256 usdcReturned);
    event FillExecuted(
        address indexed lp,
        address indexed rwaToken,
        uint256 usdcAmount,
        uint256 dobRwaAmount
    );
    event WithdrawalRequested(address indexed lp, uint256 amount, uint48 executeAfter);
    event WithdrawalCancelled(address indexed lp);
    event WithdrawalExecuted(address indexed lp, uint256 amount);
    event DobRwaClaimed(address indexed lp, uint256 amount);
    event HookSet(address indexed hook);
    event TreasurySet(address indexed treasury);
    event ProtocolFeeCollected(uint256 amount);
    event ReserveHeld(address indexed lp, address indexed rwaToken, uint256 amount);
    event ReserveReleased(address indexed lp, uint256 amount, uint256 holdIndex);
    event ProtocolFeeWithdrawn(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotRegistered();
    error AlreadyRegistered();
    error BelowMinDeposit();
    error BelowMinAllocation();
    error InsufficientAvailableUsdc();
    error AlreadyBacking();
    error NotBacking();
    error TooManyBackers();
    error InvalidPenalty();
    error NoWithdrawalPending();
    error WithdrawalNotReady();
    error WithdrawalAlreadyPending();
    error InsufficientClaimable();
    error OnlyHook();
    error ZeroAmount();
    error ReserveStillLocked();
    error InvalidHoldIndex();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _usdc, address _owner) Owned(_owner) {
        usdc = ERC20(_usdc);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setHook(address _hook) external onlyOwner {
        hook = _hook;
        emit HookSet(_hook);
    }

    function setRegistry(address _registry) external onlyOwner {
        registry = IDobValidatorRegistryLP(_registry);
    }

    function setProtocolTreasury(address _treasury) external onlyOwner {
        protocolTreasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /// @notice Withdraw accumulated protocol fees to the treasury.
    function withdrawFees() external nonReentrant onlyOwner {
        uint256 fees = accumulatedFees;
        if (fees == 0) revert ZeroAmount();

        accumulatedFees = 0;
        address to = protocolTreasury != address(0) ? protocolTreasury : owner;
        usdc.safeTransfer(to, fees);

        emit ProtocolFeeWithdrawn(to, fees);
    }

    /*//////////////////////////////////////////////////////////////
                        LP REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Register as an LP by depositing USDC.
    function register(uint256 amount) external nonReentrant {
        if (amount < MIN_DEPOSIT) revert BelowMinDeposit();
        if (positions[msg.sender].active) revert AlreadyRegistered();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        positions[msg.sender] = LPPosition({
            usdcDeposited: amount,
            usdcAvailable: amount,
            registeredAt: uint48(block.timestamp),
            active: true
        });

        emit LPRegistered(msg.sender, amount);
    }

    /// @notice Deposit additional USDC to an existing LP position.
    function depositMore(uint256 amount) external nonReentrant {
        if (!positions[msg.sender].active) revert NotRegistered();
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        positions[msg.sender].usdcDeposited += amount;
        positions[msg.sender].usdcAvailable += amount;

        emit LPDeposited(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         ASSET BACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Back a specific RWA asset with conditions and a USDC allocation.
    /// @param rwaToken       The RWA token address to back.
    /// @param minOraclePrice Minimum oracle price (18-decimal) to accept fills.
    /// @param minPenaltyBps  Minimum liquidation penalty (bps) required. 0 = accept any.
    /// @param maxExposure    Maximum dobRWA the LP will accumulate for this asset.
    /// @param usdcAllocation Amount of USDC to earmark for this asset.
    function backAsset(
        address rwaToken,
        uint256 minOraclePrice,
        uint16  minPenaltyBps,
        uint256 maxExposure,
        uint256 usdcAllocation
    ) external nonReentrant {
        if (!positions[msg.sender].active) revert NotRegistered();
        if (backings[msg.sender][rwaToken].active) revert AlreadyBacking();
        if (_assetBackers[rwaToken].length >= MAX_BACKERS_PER_ASSET) revert TooManyBackers();
        if (usdcAllocation < MIN_ALLOCATION) revert BelowMinAllocation();
        if (usdcAllocation > positions[msg.sender].usdcAvailable) revert InsufficientAvailableUsdc();
        if (minPenaltyBps > 10000) revert InvalidPenalty();
        if (maxExposure == 0) revert ZeroAmount();

        positions[msg.sender].usdcAvailable -= usdcAllocation;

        backings[msg.sender][rwaToken] = AssetBacking({
            minOraclePrice: minOraclePrice,
            minPenaltyBps: minPenaltyBps,
            maxExposure: maxExposure,
            currentExposure: 0,
            usdcAllocated: usdcAllocation,
            usdcUsed: 0,
            backedAt: uint48(block.timestamp),
            active: true
        });

        _backerIndex[rwaToken][msg.sender] = _assetBackers[rwaToken].length;
        _assetBackers[rwaToken].push(msg.sender);

        emit AssetBacked(msg.sender, rwaToken, minOraclePrice, minPenaltyBps, maxExposure, usdcAllocation);
    }

    /// @notice Update conditions for an asset you are already backing.
    ///         Does not change USDC allocation or reset exposure.
    function updateConditions(
        address rwaToken,
        uint256 minOraclePrice,
        uint16  minPenaltyBps,
        uint256 maxExposure
    ) external {
        if (!backings[msg.sender][rwaToken].active) revert NotBacking();
        if (minPenaltyBps > 10000) revert InvalidPenalty();
        if (maxExposure == 0) revert ZeroAmount();

        AssetBacking storage backing = backings[msg.sender][rwaToken];
        backing.minOraclePrice = minOraclePrice;
        backing.minPenaltyBps = minPenaltyBps;
        backing.maxExposure = maxExposure;

        emit ConditionsUpdated(msg.sender, rwaToken, minOraclePrice, minPenaltyBps, maxExposure);
    }

    /// @notice Increase the USDC allocation for an asset you are backing.
    function increaseAllocation(address rwaToken, uint256 amount) external nonReentrant {
        if (!backings[msg.sender][rwaToken].active) revert NotBacking();
        if (amount == 0) revert ZeroAmount();
        if (amount > positions[msg.sender].usdcAvailable) revert InsufficientAvailableUsdc();

        positions[msg.sender].usdcAvailable -= amount;
        backings[msg.sender][rwaToken].usdcAllocated += amount;

        emit AllocationIncreased(msg.sender, rwaToken, amount);
    }

    /// @notice Stop backing an asset. Unused USDC allocation is returned to available.
    ///         If the asset is currently distressed, 33% is held as a reserve that
    ///         unlocks when the asset returns to healthy or after RESERVE_WITHDRAWAL_DELAY.
    ///         Does NOT forfeit any dobRWA already earned from fills.
    function stopBacking(address rwaToken) external nonReentrant {
        AssetBacking storage backing = backings[msg.sender][rwaToken];
        if (!backing.active) revert NotBacking();

        uint256 usdcReturned = backing.usdcAllocated - backing.usdcUsed;
        backing.active = false;
        _removeBacker(rwaToken, msg.sender);

        // Check if the asset is distressed via the validator registry
        bool distressed = _isAssetDistressed(rwaToken);

        if (distressed && usdcReturned > 0) {
            // 33% reserve held, 67% returned immediately
            uint256 reserveAmount = (usdcReturned * RESERVE_BPS) / 10000;
            uint256 freeAmount = usdcReturned - reserveAmount;

            positions[msg.sender].usdcAvailable += freeAmount;

            reserveHolds[msg.sender].push(ReserveHold({
                amount: reserveAmount,
                rwaToken: rwaToken,
                createdAt: uint48(block.timestamp)
            }));

            emit ReserveHeld(msg.sender, rwaToken, reserveAmount);
            emit BackingStopped(msg.sender, rwaToken, freeAmount);
        } else {
            // Asset is healthy — full return
            positions[msg.sender].usdcAvailable += usdcReturned;
            emit BackingStopped(msg.sender, rwaToken, usdcReturned);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Request a withdrawal of unallocated USDC. Subject to time delay.
    function requestWithdrawal(uint256 amount) external {
        if (!positions[msg.sender].active) revert NotRegistered();
        if (amount == 0) revert ZeroAmount();
        if (amount > positions[msg.sender].usdcAvailable) revert InsufficientAvailableUsdc();
        if (withdrawalRequests[msg.sender].amount > 0) revert WithdrawalAlreadyPending();

        positions[msg.sender].usdcAvailable -= amount;

        withdrawalRequests[msg.sender] = WithdrawalRequest({
            amount: amount,
            requestedAt: uint48(block.timestamp)
        });

        emit WithdrawalRequested(msg.sender, amount, uint48(block.timestamp) + WITHDRAWAL_DELAY);
    }

    /// @notice Cancel a pending withdrawal. USDC is returned to available.
    function cancelWithdrawal() external {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.amount == 0) revert NoWithdrawalPending();

        positions[msg.sender].usdcAvailable += req.amount;
        delete withdrawalRequests[msg.sender];

        emit WithdrawalCancelled(msg.sender);
    }

    /// @notice Execute a pending withdrawal after the time delay has elapsed.
    function executeWithdrawal() external nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[msg.sender];
        if (req.amount == 0) revert NoWithdrawalPending();
        if (block.timestamp < req.requestedAt + WITHDRAWAL_DELAY) revert WithdrawalNotReady();

        uint256 amount = req.amount;
        positions[msg.sender].usdcDeposited -= amount;
        delete withdrawalRequests[msg.sender];

        if (positions[msg.sender].usdcDeposited == 0 && positions[msg.sender].usdcAvailable == 0) {
            positions[msg.sender].active = false;
        }

        usdc.safeTransfer(msg.sender, amount);

        emit WithdrawalExecuted(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        RESERVE RELEASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Release a reserve hold. Unlocks if:
    ///         1. The asset has returned to healthy (penaltyBps == 0 or liquidation disabled), OR
    ///         2. RESERVE_WITHDRAWAL_DELAY has elapsed since the hold was created.
    function releaseReserve(uint256 holdIndex) external nonReentrant {
        ReserveHold[] storage holds = reserveHolds[msg.sender];
        if (holdIndex >= holds.length) revert InvalidHoldIndex();

        ReserveHold storage hold = holds[holdIndex];
        if (hold.amount == 0) revert ZeroAmount();

        bool assetHealthy = !_isAssetDistressed(hold.rwaToken);
        bool delayElapsed = block.timestamp >= hold.createdAt + RESERVE_WITHDRAWAL_DELAY;

        if (!assetHealthy && !delayElapsed) revert ReserveStillLocked();

        uint256 amount = hold.amount;
        positions[msg.sender].usdcAvailable += amount;

        // Swap-and-pop removal
        uint256 lastIndex = holds.length - 1;
        if (holdIndex != lastIndex) {
            holds[holdIndex] = holds[lastIndex];
        }
        holds.pop();

        emit ReserveReleased(msg.sender, amount, holdIndex);
    }

    /*//////////////////////////////////////////////////////////////
                       HOOK-ONLY: FILL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Query willing LPs and execute fills for a liquidation swap.
    ///         Only callable by the authorized hook during _beforeSwap.
    /// @param rwaToken           The RWA token being liquidated.
    /// @param currentOraclePrice Current oracle price (18-decimal USD).
    /// @param currentPenaltyBps  Current liquidation penalty in basis points.
    /// @param usdcNeeded         Total USDC needed from LPs.
    /// @return totalUsdcFilled   USDC filled by LPs (transferred to hook).
    /// @return totalDobRwaForLPs dobRWA credited to LPs from this fill.
    function queryAndFill(
        address rwaToken,
        uint256 currentOraclePrice,
        uint16  currentPenaltyBps,
        uint256 usdcNeeded
    ) external nonReentrant returns (uint256 totalUsdcFilled, uint256 totalDobRwaForLPs) {
        if (msg.sender != hook) revert OnlyHook();

        address[] storage backers = _assetBackers[rwaToken];
        uint256 remaining = usdcNeeded;

        for (uint256 i = 0; i < backers.length && remaining > 0; i++) {
            (uint256 filled, uint256 dobRwa) = _tryFillLP(
                backers[i], rwaToken, currentOraclePrice, currentPenaltyBps, remaining
            );
            if (filled == 0) continue;

            totalDobRwaForLPs += dobRwa;
            uint256 fee = (filled * PROTOCOL_FEE_BPS) / 10000;
            accumulatedFees += fee;
            uint256 net = filled - fee;
            remaining -= net;
            totalUsdcFilled += net;
        }

        // Transfer filled USDC (minus fees) to the hook
        if (totalUsdcFilled > 0) {
            usdc.safeTransfer(hook, totalUsdcFilled);
        }

        if (accumulatedFees > 0) {
            emit ProtocolFeeCollected(accumulatedFees);
        }
    }

    /*//////////////////////////////////////////////////////////////
                   HOOK-ONLY: MARKET-RATE FILL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Fill LPs at each LP's own minPenaltyBps (market-rate fills).
    ///         Used by the hook when USDC reserves are insufficient for a normal
    ///         sell — no protocol-mandated liquidation needed, LPs set their own
    ///         discount and the system fills in FIFO order.
    /// @param rwaToken           The RWA token whose dUSDC is being sold.
    /// @param currentOraclePrice Current oracle price (18-decimal USD).
    /// @param usdcNeeded         USDC shortfall to fill from LPs.
    /// @return totalUsdcFilled   USDC filled by LPs (transferred to hook).
    /// @return totalDobRwaForLPs dobRWA credited to LPs from this fill.
    function queryAndFillAtMarket(
        address rwaToken,
        uint256 currentOraclePrice,
        uint256 usdcNeeded
    ) external nonReentrant returns (uint256 totalUsdcFilled, uint256 totalDobRwaForLPs) {
        if (msg.sender != hook) revert OnlyHook();

        address[] storage backers = _assetBackers[rwaToken];
        uint256 remaining = usdcNeeded;

        for (uint256 i = 0; i < backers.length && remaining > 0; i++) {
            (uint256 filled, uint256 dobRwa) = _tryFillLPAtMarket(
                backers[i], rwaToken, currentOraclePrice, remaining
            );
            if (filled == 0) continue;

            totalDobRwaForLPs += dobRwa;
            uint256 fee = (filled * PROTOCOL_FEE_BPS) / 10000;
            accumulatedFees += fee;
            uint256 net = filled - fee;
            remaining -= net;
            totalUsdcFilled += net;
        }

        // Transfer filled USDC (minus fees) to the hook
        if (totalUsdcFilled > 0) {
            usdc.safeTransfer(hook, totalUsdcFilled);
        }

        if (accumulatedFees > 0) {
            emit ProtocolFeeCollected(accumulatedFees);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        DOBRWA CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim accumulated RWA tokens from liquidation fills.
    ///         Calls the hook to convert dobRWA → RWA tokens via the vault.
    /// @param rwaToken    The RWA token address to claim.
    /// @param dobRwaAmount The amount of dobRWA to convert to RWA tokens.
    function claimRwaTokens(address rwaToken, uint256 dobRwaAmount) external nonReentrant {
        if (dobRwaAmount == 0) revert ZeroAmount();
        if (rwaOwed[msg.sender][rwaToken] < dobRwaAmount) revert InsufficientClaimable();

        rwaOwed[msg.sender][rwaToken] -= dobRwaAmount;

        IDobPegHookLP(hook).releaseRwaTokens(msg.sender, rwaToken, dobRwaAmount);

        emit DobRwaClaimed(msg.sender, dobRwaAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getAssetBackerCount(address rwaToken) external view returns (uint256) {
        return _assetBackers[rwaToken].length;
    }

    function getAssetBackers(address rwaToken) external view returns (address[] memory) {
        return _assetBackers[rwaToken];
    }

    /// @notice Total available (unfilled) USDC across all active backers of an asset.
    function getAssetLiquidity(address rwaToken) external view returns (uint256 totalAvailable) {
        address[] storage backers = _assetBackers[rwaToken];
        for (uint256 i = 0; i < backers.length; i++) {
            AssetBacking storage backing = backings[backers[i]][rwaToken];
            if (backing.active) {
                totalAvailable += backing.usdcAllocated - backing.usdcUsed;
            }
        }
    }

    function getBacking(address lp, address rwaToken) external view returns (AssetBacking memory) {
        return backings[lp][rwaToken];
    }

    function getReserveHolds(address lp) external view returns (ReserveHold[] memory) {
        return reserveHolds[lp];
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Check whether an asset is currently in distressed (liquidation) mode.
    function _isAssetDistressed(address rwaToken) internal view returns (bool) {
        if (address(registry) == address(0)) return false;
        (bool enabled, uint16 penaltyBps,,) = registry.getLiquidationParams(rwaToken);
        return enabled && penaltyBps > 0;
    }

    /// @dev Attempt to fill a single LP for a liquidation. Returns (usdcFilled, dobRwaAmount).
    function _tryFillLP(
        address lp,
        address rwaToken,
        uint256 currentOraclePrice,
        uint16 currentPenaltyBps,
        uint256 remaining
    ) internal returns (uint256 fillUsdc, uint256 dobRwaAmount) {
        AssetBacking storage backing = backings[lp][rwaToken];

        if (!backing.active) return (0, 0);
        if (block.timestamp - backing.backedAt < MIN_BACKING_AGE) return (0, 0);
        if (currentOraclePrice < backing.minOraclePrice) return (0, 0);
        if (currentPenaltyBps < backing.minPenaltyBps) return (0, 0);

        uint256 availableUsdc = backing.usdcAllocated - backing.usdcUsed;
        if (availableUsdc == 0) return (0, 0);

        uint256 remainingExposure = backing.maxExposure - backing.currentExposure;
        if (remainingExposure == 0) return (0, 0);

        fillUsdc = remaining;
        if (fillUsdc > availableUsdc) fillUsdc = availableUsdc;

        dobRwaAmount = (fillUsdc * 10000) / (10000 - currentPenaltyBps);

        if (dobRwaAmount > remainingExposure) {
            dobRwaAmount = remainingExposure;
            fillUsdc = (dobRwaAmount * (10000 - currentPenaltyBps)) / 10000;
        }

        if (fillUsdc == 0) return (0, 0);

        backing.usdcUsed += fillUsdc;
        backing.currentExposure += dobRwaAmount;
        rwaOwed[lp][rwaToken] += dobRwaAmount;

        emit FillExecuted(lp, rwaToken, fillUsdc, dobRwaAmount);
    }

    /// @dev Attempt to fill a single LP at their own minPenaltyBps (market rate).
    function _tryFillLPAtMarket(
        address lp,
        address rwaToken,
        uint256 currentOraclePrice,
        uint256 remaining
    ) internal returns (uint256 fillUsdc, uint256 dobRwaAmount) {
        AssetBacking storage backing = backings[lp][rwaToken];

        if (!backing.active) return (0, 0);
        if (block.timestamp - backing.backedAt < MIN_BACKING_AGE) return (0, 0);
        if (currentOraclePrice < backing.minOraclePrice) return (0, 0);

        // Use LP's own minPenaltyBps as the discount rate
        uint16 lpPenalty = backing.minPenaltyBps;
        if (lpPenalty == 0) lpPenalty = 1; // at least 1bp for LP to profit

        uint256 availableUsdc = backing.usdcAllocated - backing.usdcUsed;
        if (availableUsdc == 0) return (0, 0);

        uint256 remainingExposure = backing.maxExposure - backing.currentExposure;
        if (remainingExposure == 0) return (0, 0);

        fillUsdc = remaining;
        if (fillUsdc > availableUsdc) fillUsdc = availableUsdc;

        dobRwaAmount = (fillUsdc * 10000) / (10000 - lpPenalty);

        if (dobRwaAmount > remainingExposure) {
            dobRwaAmount = remainingExposure;
            fillUsdc = (dobRwaAmount * (10000 - lpPenalty)) / 10000;
        }

        if (fillUsdc == 0) return (0, 0);

        backing.usdcUsed += fillUsdc;
        backing.currentExposure += dobRwaAmount;
        rwaOwed[lp][rwaToken] += dobRwaAmount;

        emit FillExecuted(lp, rwaToken, fillUsdc, dobRwaAmount);
    }

    /// @dev Remove an LP from the assetBackers array using swap-and-pop.
    function _removeBacker(address rwaToken, address lp) internal {
        uint256 index = _backerIndex[rwaToken][lp];
        uint256 lastIndex = _assetBackers[rwaToken].length - 1;

        if (index != lastIndex) {
            address lastBacker = _assetBackers[rwaToken][lastIndex];
            _assetBackers[rwaToken][index] = lastBacker;
            _backerIndex[rwaToken][lastBacker] = index;
        }

        _assetBackers[rwaToken].pop();
        delete _backerIndex[rwaToken][lp];
    }
}

/// @notice Minimal interface for the hook's LP release function.
interface IDobPegHookLP {
    function releaseRwaTokens(address to, address rwaToken, uint256 dobRwaAmount) external;
}

/// @notice Minimal interface for querying the validator registry's liquidation state.
interface IDobValidatorRegistryLP {
    function getLiquidationParams(address token)
        external
        view
        returns (bool enabled, uint16 penaltyBps, uint256 cap, uint256 liquidatedAmount);
}
