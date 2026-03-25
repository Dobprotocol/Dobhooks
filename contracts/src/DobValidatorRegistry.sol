// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";

/// @title DobValidatorRegistry
/// @notice On-chain oracle updated by Dobprotocol's AI validator agents.
///         Maps RWA token contract addresses to validated USD valuations
///         and liquidation parameters (penalty, per-asset cap, global cap).
contract DobValidatorRegistry is Owned {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct PriceData {
        uint256 priceUsd;           // 18-decimal USD price per token
        uint48 updatedAt;           // timestamp of the last update
    }

    struct LiquidationData {
        bool enabled;               // true = asset is in liquidation mode
        uint16 penaltyBps;          // penalty in basis points (e.g., 2000 = 20%)
        uint256 cap;                // max dobRWA that can be liquidated for this asset
        uint256 liquidatedAmount;   // running total already liquidated
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum allowed delay (seconds) before a price is considered stale.
    uint48 public constant MAX_ORACLE_DELAY = 1 days;

    /// @notice RWA token address → validated price data
    mapping(address => PriceData) public prices;

    /// @notice RWA token address → liquidation parameters
    mapping(address => LiquidationData) public liquidations;

    /// @notice Global liquidation cap across all assets (in dobRWA units, 18-decimal).
    uint256 public globalLiquidationCap;

    /// @notice Global running total of all liquidated dobRWA.
    uint256 public globalLiquidatedAmount;

    /// @notice The authorized hook address that can record liquidations.
    address public hook;

    /// @notice Maximum allowed price change per update in basis points (e.g. 5000 = 50%).
    ///         0 = no limit (default for first price set).
    uint16 public maxPriceChangeBps;

    /// @notice Emergency pause flag.
    bool public paused;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PriceUpdated(address indexed token, uint256 priceUsd, uint48 timestamp);
    event LiquidationEnabled(address indexed token, uint16 penaltyBps, uint256 cap);
    event LiquidationDisabled(address indexed token);
    event LiquidationRecorded(address indexed token, uint256 amount, uint256 totalLiquidated);
    event GlobalLiquidationCapSet(uint256 cap);
    event HookSet(address indexed hook);
    event MaxPriceChangeSet(uint16 maxBps);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PriceNotSet();
    error ZeroPrice();
    error InvalidPenalty();
    error ZeroCap();
    error OnlyHook();
    error PriceChangeTooLarge();
    error ContractPaused();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) Owned(_owner) {}

    /*//////////////////////////////////////////////////////////////
                           ORACLE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set or update the USD price for an RWA token.
    /// @param token The ERC-20 address of the RWA token.
    /// @param priceUsd The 18-decimal USD price per 1e18 base units of `token`.
    function setPrice(address token, uint256 priceUsd) external onlyOwner {
        if (paused) revert ContractPaused();
        if (priceUsd == 0) revert ZeroPrice();

        // Enforce max price change if a previous price exists and limit is set
        uint256 oldPrice = prices[token].priceUsd;
        if (oldPrice > 0 && maxPriceChangeBps > 0) {
            uint256 maxDelta = (oldPrice * maxPriceChangeBps) / 10000;
            uint256 delta = priceUsd > oldPrice ? priceUsd - oldPrice : oldPrice - priceUsd;
            if (delta > maxDelta) revert PriceChangeTooLarge();
        }

        prices[token] = PriceData({priceUsd: priceUsd, updatedAt: uint48(block.timestamp)});

        emit PriceUpdated(token, priceUsd, uint48(block.timestamp));
    }

    /// @notice Read the current price for an RWA token.
    /// @return priceUsd The 18-decimal USD price.
    /// @return updatedAt The timestamp when the price was last set.
    function getPrice(address token) external view returns (uint256 priceUsd, uint48 updatedAt) {
        PriceData memory data = prices[token];
        if (data.updatedAt == 0) revert PriceNotSet();
        return (data.priceUsd, data.updatedAt);
    }

    /*//////////////////////////////////////////////////////////////
                       LIQUIDATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the authorized hook address that can record liquidations.
    function setHook(address _hook) external onlyOwner {
        hook = _hook;
        emit HookSet(_hook);
    }

    /// @notice Enable liquidation mode for an RWA token.
    /// @param token      The RWA token address.
    /// @param penaltyBps Penalty in basis points (1-10000). E.g., 2000 = 20% penalty.
    /// @param cap        Maximum dobRWA amount that can be liquidated for this asset.
    function setLiquidationParams(address token, uint16 penaltyBps, uint256 cap) external onlyOwner {
        if (paused) revert ContractPaused();
        if (penaltyBps == 0 || penaltyBps > 10000) revert InvalidPenalty();
        if (cap == 0) revert ZeroCap();

        liquidations[token] = LiquidationData({
            enabled: true,
            penaltyBps: penaltyBps,
            cap: cap,
            liquidatedAmount: liquidations[token].liquidatedAmount // preserve running total
        });

        emit LiquidationEnabled(token, penaltyBps, cap);
    }

    /// @notice Disable liquidation mode for an RWA token.
    ///         Resets the per-asset liquidated counter so a future re-enable starts fresh.
    function disableLiquidation(address token) external onlyOwner {
        uint256 liquidatedBefore = liquidations[token].liquidatedAmount;
        if (liquidatedBefore > 0) {
            globalLiquidatedAmount -= liquidatedBefore;
        }
        liquidations[token].enabled = false;
        liquidations[token].liquidatedAmount = 0;
        emit LiquidationDisabled(token);
    }

    /// @notice Set the global liquidation cap across all assets.
    /// @param cap Maximum total dobRWA that can be liquidated globally.
    function setGlobalLiquidationCap(uint256 cap) external onlyOwner {
        if (cap == 0) revert ZeroCap();
        globalLiquidationCap = cap;
        emit GlobalLiquidationCapSet(cap);
    }

    /// @notice Set the maximum allowed price change per update.
    /// @param maxBps Maximum change in basis points (e.g. 5000 = 50%). 0 = no limit.
    function setMaxPriceChange(uint16 maxBps) external onlyOwner {
        maxPriceChangeBps = maxBps;
        emit MaxPriceChangeSet(maxBps);
    }

    /// @notice Emergency price set that bypasses the maxPriceChangeBps limit.
    ///         Use only when a legitimate large price correction is needed.
    function emergencySetPrice(address token, uint256 priceUsd) external onlyOwner {
        if (priceUsd == 0) revert ZeroPrice();
        prices[token] = PriceData({priceUsd: priceUsd, updatedAt: uint48(block.timestamp)});
        emit PriceUpdated(token, priceUsd, uint48(block.timestamp));
    }

    /// @notice Pause the contract.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the contract.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Record a liquidation event. Only callable by the authorized hook.
    /// @param token  The RWA token whose dobRWA is being liquidated.
    /// @param amount The amount of dobRWA being liquidated.
    function recordLiquidation(address token, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();

        liquidations[token].liquidatedAmount += amount;
        globalLiquidatedAmount += amount;

        emit LiquidationRecorded(token, amount, liquidations[token].liquidatedAmount);
    }

    /// @notice Read liquidation parameters for an RWA token.
    function getLiquidationParams(address token)
        external
        view
        returns (bool enabled, uint16 penaltyBps, uint256 cap, uint256 liquidatedAmount)
    {
        LiquidationData memory data = liquidations[token];
        return (data.enabled, data.penaltyBps, data.cap, data.liquidatedAmount);
    }
}
