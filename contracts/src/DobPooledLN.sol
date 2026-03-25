// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {DobLPRegistry} from "./DobLPRegistry.sol";

/// @title DobPooledLN
/// @notice Shared Liquidity Node — a pooled USDC vault that acts as a single LP
///         position in the DobLPRegistry. Managed by Dobprotocol (or any operator),
///         open for anyone to deposit USDC and earn proportional shares of the
///         RWA tokens the LN acquires from fills.
///
///         The operator decides which assets to back and sets discount rates,
///         which can be updated dynamically based on on-chain or off-chain data.
///
///         Multiple DobPooledLN instances can exist (one per strategy, or a
///         single "main LN" managed by Dobprotocol).
contract DobPooledLN is Owned, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The USDC token.
    ERC20 public immutable usdc;

    /// @notice The DobLPRegistry this pooled LN operates in.
    DobLPRegistry public immutable lpRegistry;

    /// @notice Total USDC managed by this pooled LN (deposits - withdrawals).
    uint256 public totalPoolUsdc;

    /// @notice Total outstanding shares.
    uint256 public totalShares;

    /// @notice Depositor address => share balance.
    mapping(address => uint256) public shares;

    /// @notice Depositor address => deposit timestamp (for MIN_DEPOSIT_DURATION).
    mapping(address => uint48) public depositedAt;

    /// @notice Minimum time before a depositor can withdraw.
    uint48 public constant MIN_DEPOSIT_DURATION = 1 hours;

    /// @notice Dead shares to prevent first-depositor attack.
    uint256 private constant DEAD_SHARES = 1000;

    /// @notice Minimum deposit amount.
    uint256 public minDeposit;

    /// @notice Emergency pause flag.
    bool public paused;

    /// @notice Whether this pooled LN has registered in the LP registry.
    bool public registered;

    // ── RWA Token Tracking ──

    /// @notice rwaToken => total RWA owed to this pooled LN (from fills).
    mapping(address => uint256) public totalRwaOwed;

    /// @notice rwaToken => total RWA already claimed from registry.
    mapping(address => uint256) public totalRwaClaimed;

    /// @notice rwaToken => total RWA allocated but not yet withdrawn by depositors.
    mapping(address => uint256) public totalRwaPending;

    /// @notice depositor => rwaToken => RWA tokens available to withdraw.
    mapping(address => mapping(address => uint256)) public rwaClaimable;

    /// @notice List of RWA tokens that have been backed (for enumeration).
    address[] public backedAssets;

    /// @notice rwaToken => whether it's in the backedAssets array.
    mapping(address => bool) public isBackedAsset;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed depositor, uint256 amount, uint256 sharesIssued);
    event Withdrawn(address indexed depositor, uint256 sharesBurned, uint256 amount);
    event AssetBacked(address indexed rwaToken, uint256 minOraclePrice, uint16 minPenaltyBps, uint256 maxExposure, uint256 usdcAllocation);
    event AssetStopped(address indexed rwaToken);
    event DiscountUpdated(address indexed rwaToken, uint16 newPenaltyBps);
    event ConditionsUpdated(address indexed rwaToken, uint256 minOraclePrice, uint16 minPenaltyBps, uint256 maxExposure);
    event AllocationIncreased(address indexed rwaToken, uint256 amount);
    event RwaClaimed(address indexed rwaToken, uint256 amount);
    event RwaDistributed(address indexed rwaToken, address indexed depositor, uint256 amount);
    event CapitalAdded(uint256 amount);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event MinDepositSet(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ContractPaused();
    error ZeroAmount();
    error BelowMinDeposit();
    error InsufficientShares();
    error DepositDurationNotMet();
    error NotRegistered();
    error AlreadyRegistered();
    error NothingToClaim();
    error InsufficientRwa();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _usdc       The USDC token address.
    /// @param _lpRegistry The DobLPRegistry this pooled LN operates in.
    /// @param _owner      The operator (e.g., Dobprotocol admin).
    /// @param _minDeposit Minimum USDC deposit amount.
    constructor(
        address _usdc,
        address _lpRegistry,
        address _owner,
        uint256 _minDeposit
    ) Owned(_owner) {
        usdc = ERC20(_usdc);
        lpRegistry = DobLPRegistry(_lpRegistry);
        minDeposit = _minDeposit;
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setMinDeposit(uint256 amount) external onlyOwner {
        minDeposit = amount;
        emit MinDepositSet(amount);
    }

    /*//////////////////////////////////////////////////////////////
                    REGISTER IN LP REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Register this pooled LN as an LP in the DobLPRegistry.
    ///         Called once. The initial USDC is pulled from the pool's balance.
    /// @param amount Initial USDC to register with.
    function registerInRegistry(uint256 amount) external onlyOwner nonReentrant {
        if (registered) revert AlreadyRegistered();
        if (amount == 0) revert ZeroAmount();

        registered = true;

        usdc.safeApprove(address(lpRegistry), type(uint256).max);
        lpRegistry.register(amount);

        emit CapitalAdded(amount);
    }

    /// @notice Deposit more USDC into the LP registry position from the pool.
    /// @param amount USDC to add to the registry position.
    function addCapitalToRegistry(uint256 amount) external onlyOwner nonReentrant {
        if (!registered) revert NotRegistered();
        if (amount == 0) revert ZeroAmount();

        lpRegistry.depositMore(amount);

        emit CapitalAdded(amount);
    }

    /*//////////////////////////////////////////////////////////////
                    ASSET BACKING (ADMIN ONLY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Back a specific RWA asset. Operator decides which tokens
    ///         this pooled LN provides exit liquidity for.
    /// @param rwaToken       The RWA token to back.
    /// @param minOraclePrice Minimum oracle price to accept fills (18-decimal).
    /// @param minPenaltyBps  Discount rate this LN requires (bps). The seller
    ///                       pays this discount, LN earns discounted RWA tokens.
    /// @param maxExposure    Maximum dobRWA to accumulate for this asset.
    /// @param usdcAllocation USDC to earmark for this asset.
    function backAsset(
        address rwaToken,
        uint256 minOraclePrice,
        uint16  minPenaltyBps,
        uint256 maxExposure,
        uint256 usdcAllocation
    ) external onlyOwner {
        if (!registered) revert NotRegistered();

        lpRegistry.backAsset(rwaToken, minOraclePrice, minPenaltyBps, maxExposure, usdcAllocation);

        if (!isBackedAsset[rwaToken]) {
            backedAssets.push(rwaToken);
            isBackedAsset[rwaToken] = true;
        }

        emit AssetBacked(rwaToken, minOraclePrice, minPenaltyBps, maxExposure, usdcAllocation);
    }

    /// @notice Stop backing an asset. Unused USDC returns to available.
    function stopBacking(address rwaToken) external onlyOwner {
        lpRegistry.stopBacking(rwaToken);
        emit AssetStopped(rwaToken);
    }

    /// @notice Increase the USDC allocation for a backed asset.
    function increaseAllocation(address rwaToken, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        lpRegistry.increaseAllocation(rwaToken, amount);
        emit AllocationIncreased(rwaToken, amount);
    }

    /*//////////////////////////////////////////////////////////////
                   DYNAMIC DISCOUNT UPDATES
    //////////////////////////////////////////////////////////////*/

    /// @notice Update the discount (minPenaltyBps) for a backed asset.
    ///         Can be called at any time based on on-chain or off-chain data.
    /// @param rwaToken      The backed RWA token.
    /// @param newPenaltyBps New discount rate in basis points.
    function updateDiscount(address rwaToken, uint16 newPenaltyBps) external onlyOwner {
        DobLPRegistry.AssetBacking memory backing = lpRegistry.getBacking(address(this), rwaToken);
        lpRegistry.updateConditions(
            rwaToken,
            backing.minOraclePrice,
            newPenaltyBps,
            backing.maxExposure
        );
        emit DiscountUpdated(rwaToken, newPenaltyBps);
    }

    /// @notice Update all conditions for a backed asset at once.
    function updateConditions(
        address rwaToken,
        uint256 minOraclePrice,
        uint16  minPenaltyBps,
        uint256 maxExposure
    ) external onlyOwner {
        lpRegistry.updateConditions(rwaToken, minOraclePrice, minPenaltyBps, maxExposure);
        emit ConditionsUpdated(rwaToken, minOraclePrice, minPenaltyBps, maxExposure);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSITOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit USDC into the pooled LN and receive shares.
    ///         Shares represent proportional ownership of the pool's USDC
    ///         and future RWA token earnings.
    function deposit(uint256 amount) external nonReentrant returns (uint256 sharesOut) {
        if (paused) revert ContractPaused();
        if (amount < minDeposit) revert BelowMinDeposit();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (totalShares == 0) {
            require(amount > DEAD_SHARES, "First deposit too small");
            sharesOut = amount - DEAD_SHARES;
            totalShares = amount;
            shares[address(1)] += DEAD_SHARES;
        } else {
            sharesOut = (amount * totalShares) / totalPoolUsdc;
            totalShares += sharesOut;
        }

        totalPoolUsdc += amount;
        shares[msg.sender] += sharesOut;
        depositedAt[msg.sender] = uint48(block.timestamp);

        emit Deposited(msg.sender, amount, sharesOut);
    }

    /// @notice Withdraw USDC from the pooled LN by burning shares.
    ///         Only withdraws from unallocated USDC (not locked in backings).
    function withdraw(uint256 sharesToBurn) external nonReentrant returns (uint256 amount) {
        if (sharesToBurn == 0) revert ZeroAmount();
        if (shares[msg.sender] < sharesToBurn) revert InsufficientShares();
        if (block.timestamp < depositedAt[msg.sender] + MIN_DEPOSIT_DURATION) revert DepositDurationNotMet();

        amount = (sharesToBurn * totalPoolUsdc) / totalShares;

        // Can only withdraw what's actually available in this contract
        uint256 available = usdc.balanceOf(address(this));
        if (amount > available) revert InsufficientShares();

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalPoolUsdc -= amount;

        usdc.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, sharesToBurn, amount);
    }

    /*//////////////////////////////////////////////////////////////
                   RWA CLAIM & DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim RWA tokens from the LP registry. The registry converts
    ///         dobRWA → underlying RWA tokens via the hook + vault.
    ///         After claiming, RWA tokens sit in this contract ready for distribution.
    /// @param rwaToken    The RWA token to claim.
    /// @param dobRwaAmount Amount of dobRWA to claim.
    function claimRwaFromRegistry(address rwaToken, uint256 dobRwaAmount) external onlyOwner nonReentrant {
        if (dobRwaAmount == 0) revert ZeroAmount();

        lpRegistry.claimRwaTokens(rwaToken, dobRwaAmount);
        totalRwaClaimed[rwaToken] += dobRwaAmount;

        emit RwaClaimed(rwaToken, dobRwaAmount);
    }

    /// @notice Distribute RWA tokens to a depositor proportional to their share.
    ///         The depositor can then withdraw the RWA tokens.
    /// @param rwaToken  The RWA token to distribute.
    /// @param depositor The depositor to receive the distribution.
    function distributeRwa(address rwaToken, address depositor) external onlyOwner {
        if (shares[depositor] == 0) revert ZeroAmount();

        uint256 rwaBalance = ERC20(rwaToken).balanceOf(address(this));
        uint256 undistributed = rwaBalance - totalRwaPending[rwaToken];
        if (undistributed == 0) revert NothingToClaim();

        uint256 depositorShare = (undistributed * shares[depositor]) / totalShares;
        if (depositorShare == 0) revert ZeroAmount();

        rwaClaimable[depositor][rwaToken] += depositorShare;
        totalRwaPending[rwaToken] += depositorShare;

        emit RwaDistributed(rwaToken, depositor, depositorShare);
    }

    /// @notice Batch distribute RWA tokens to multiple depositors.
    function batchDistributeRwa(address rwaToken, address[] calldata depositors) external onlyOwner {
        uint256 rwaBalance = ERC20(rwaToken).balanceOf(address(this));
        uint256 undistributed = rwaBalance - totalRwaPending[rwaToken];
        if (undistributed == 0) revert NothingToClaim();

        for (uint256 i = 0; i < depositors.length; i++) {
            address depositor = depositors[i];
            if (shares[depositor] == 0) continue;

            uint256 depositorShare = (undistributed * shares[depositor]) / totalShares;
            if (depositorShare == 0) continue;

            rwaClaimable[depositor][rwaToken] += depositorShare;
            totalRwaPending[rwaToken] += depositorShare;

            emit RwaDistributed(rwaToken, depositor, depositorShare);
        }
    }

    /// @notice Withdraw RWA tokens that have been distributed to you.
    function withdrawRwa(address rwaToken, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (rwaClaimable[msg.sender][rwaToken] < amount) revert InsufficientRwa();

        rwaClaimable[msg.sender][rwaToken] -= amount;
        totalRwaPending[rwaToken] -= amount;
        ERC20(rwaToken).safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current price per share (18-decimal).
    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalPoolUsdc * 1e18) / totalShares;
    }

    /// @notice Number of backed assets.
    function backedAssetCount() external view returns (uint256) {
        return backedAssets.length;
    }

    /// @notice Get backing details for a specific asset from the registry.
    function getBacking(address rwaToken) external view returns (DobLPRegistry.AssetBacking memory) {
        return lpRegistry.getBacking(address(this), rwaToken);
    }

    /// @notice Get the RWA owed to this pooled LN for a specific asset.
    function getRwaOwed(address rwaToken) external view returns (uint256) {
        return lpRegistry.rwaOwed(address(this), rwaToken);
    }

}
