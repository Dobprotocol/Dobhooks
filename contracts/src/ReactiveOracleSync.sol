// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Reactive Network Interfaces
/// @notice Interfaces for subscribing to cross-chain events and handling callbacks
interface ISubscriptionService {
    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;

    function unsubscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;
}

interface IReactive {
    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3,
        bytes calldata data,
        uint256 block_number,
        uint256 op_code
    ) external;
}

/// @title ReactiveOracleSync
/// @notice Deployed on Reactive Network (Lasna Testnet, chain 5318007).
///         Subscribes to PriceUpdated events from DobValidatorRegistry on Unichain Sepolia
///         and triggers cross-chain callbacks when prices drop below alert thresholds.
///
/// @dev Architecture:
///   - This contract runs in two environments simultaneously:
///     1. Reactive Network (RNK) — for user interactions, subscriptions, and state reads
///     2. ReactVM — private execution environment that processes events
///   - When PriceUpdated fires on Unichain, ReactVM calls react()
///   - If price < threshold, emits Callback event → Reactive Network delivers it
///     to OracleAlertReceiver on Unichain via the Callback Proxy
///
/// Partner Integration: Reactive Network (https://reactive.network)
contract ReactiveOracleSync is IReactive {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reactive Network system contract for event subscriptions
    address constant REACTIVE_SYSTEM = 0x0000000000000000000000000000000000fffFfF;

    /// @notice Wildcard value — subscribes to all values for a given topic slot
    uint256 constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f51571769c6c80d34e26fc93e2fa3ee2fe4ecc49;

    /// @notice Event signature: PriceUpdated(address indexed token, uint256 priceUsd, uint48 timestamp)
    uint256 constant PRICE_UPDATED_TOPIC = uint256(keccak256("PriceUpdated(address,uint256,uint48)"));

    /// @notice Event signature: LiquidationEnabled(address indexed token, uint16 penaltyBps, uint256 cap)
    uint256 constant LIQUIDATION_ENABLED_TOPIC = uint256(keccak256("LiquidationEnabled(address,uint16,uint256)"));

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted by ReactVM to trigger a cross-chain callback
    event Callback(
        uint256 indexed chain_id,
        address indexed _contract,
        uint64 gas_limit,
        bytes payload
    );

    /// @notice Emitted when a price update is synced from the origin chain
    event PriceSynced(
        uint256 indexed srcChainId,
        address indexed token,
        uint256 newPrice,
        uint256 previousPrice
    );

    /// @notice Emitted when a price drops below the alert threshold
    event LiquidationAlert(
        uint256 indexed srcChainId,
        address indexed token,
        uint256 price,
        uint256 threshold
    );

    /*//////////////////////////////////////////////////////////////
                               TYPES
    //////////////////////////////////////////////////////////////*/

    struct PriceRecord {
        uint256 price;
        uint256 lastUpdated;
        uint256 updateCount;
    }

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The chain ID being monitored (Unichain Sepolia = 1301)
    uint256 public immutable originChainId;

    /// @notice The DobValidatorRegistry address on the origin chain
    address public immutable registryAddress;

    /// @notice The OracleAlertReceiver address on the origin chain (callback target)
    address public callbackTarget;

    /// @notice Contract owner
    address public owner;

    /// @notice Token → latest tracked price data
    mapping(address => PriceRecord) public trackedPrices;

    /// @notice Token → price threshold (below which triggers liquidation alert callback)
    mapping(address => uint256) public alertThresholds;

    /// @notice Total number of price syncs processed
    uint256 public totalSyncs;

    /// @notice Total number of liquidation alerts triggered
    uint256 public totalAlerts;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy and subscribe to oracle events on the origin chain.
    /// @param _originChainId  Chain ID to monitor (1301 for Unichain Sepolia)
    /// @param _registryAddress DobValidatorRegistry address on origin chain
    /// @param _callbackTarget  OracleAlertReceiver address on origin chain
    constructor(
        uint256 _originChainId,
        address _registryAddress,
        address _callbackTarget
    ) {
        originChainId = _originChainId;
        registryAddress = _registryAddress;
        callbackTarget = _callbackTarget;
        owner = msg.sender;

        // Subscribe to PriceUpdated events from the registry on Unichain
        // topic_0 = event signature, topic_1-3 = REACTIVE_IGNORE (wildcard)
        ISubscriptionService(REACTIVE_SYSTEM).subscribe(
            _originChainId,
            _registryAddress,
            PRICE_UPDATED_TOPIC,
            REACTIVE_IGNORE,  // any token address
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        // Subscribe to LiquidationEnabled events
        ISubscriptionService(REACTIVE_SYSTEM).subscribe(
            _originChainId,
            _registryAddress,
            LIQUIDATION_ENABLED_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /*//////////////////////////////////////////////////////////////
                        REACTIVE CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by ReactVM when a subscribed event fires on the origin chain.
    /// @dev Processes PriceUpdated events and triggers callbacks if thresholds are breached.
    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3,
        bytes calldata data,
        uint256 block_number,
        uint256 op_code
    ) external {
        if (topic_0 == PRICE_UPDATED_TOPIC) {
            _handlePriceUpdate(chain_id, topic_1, data);
        } else if (topic_0 == LIQUIDATION_ENABLED_TOPIC) {
            _handleLiquidationEnabled(chain_id, topic_1, data);
        }
    }

    /// @dev Process a PriceUpdated event
    function _handlePriceUpdate(
        uint256 chain_id,
        uint256 topic_1,
        bytes calldata data
    ) internal {
        // topic_1 = indexed token address (left-padded to 32 bytes)
        address token = address(uint160(topic_1));

        // Decode non-indexed data: (uint256 priceUsd, uint48 timestamp)
        (uint256 priceUsd, ) = abi.decode(data, (uint256, uint48));

        // Track previous price for change detection
        uint256 previousPrice = trackedPrices[token].price;

        // Update tracked price
        trackedPrices[token] = PriceRecord({
            price: priceUsd,
            lastUpdated: block.timestamp,
            updateCount: trackedPrices[token].updateCount + 1
        });
        totalSyncs++;

        emit PriceSynced(chain_id, token, priceUsd, previousPrice);

        // Check if price dropped below alert threshold → trigger callback
        uint256 threshold = alertThresholds[token];
        if (threshold > 0 && priceUsd < threshold) {
            totalAlerts++;
            emit LiquidationAlert(chain_id, token, priceUsd, threshold);

            // Emit Callback to deliver alert to OracleAlertReceiver on Unichain
            if (callbackTarget != address(0)) {
                bytes memory payload = abi.encodeWithSignature(
                    "onPriceAlert(address,uint256,uint256)",
                    token,
                    priceUsd,
                    threshold
                );
                emit Callback(chain_id, callbackTarget, 300_000, payload);
            }
        }
    }

    /// @dev Process a LiquidationEnabled event — auto-trigger callback notification
    function _handleLiquidationEnabled(
        uint256 chain_id,
        uint256 topic_1,
        bytes calldata data
    ) internal {
        address token = address(uint160(topic_1));
        (uint16 penaltyBps, uint256 cap) = abi.decode(data, (uint16, uint256));

        // Notify callback target that liquidation was enabled
        if (callbackTarget != address(0)) {
            bytes memory payload = abi.encodeWithSignature(
                "onLiquidationEnabled(address,uint16,uint256)",
                token,
                penaltyBps,
                cap
            );
            emit Callback(chain_id, callbackTarget, 200_000, payload);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the price threshold below which a liquidation alert is triggered.
    /// @param token     The RWA token address on the origin chain.
    /// @param threshold The price threshold in 18-decimal USD. Set to 0 to disable.
    function setAlertThreshold(address token, uint256 threshold) external onlyOwner {
        alertThresholds[token] = threshold;
    }

    /// @notice Batch set alert thresholds for multiple tokens.
    function setAlertThresholds(
        address[] calldata tokens,
        uint256[] calldata thresholds
    ) external onlyOwner {
        require(tokens.length == thresholds.length, "Length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            alertThresholds[tokens[i]] = thresholds[i];
        }
    }

    /// @notice Update the callback target address on the destination chain.
    function setCallbackTarget(address _target) external onlyOwner {
        callbackTarget = _target;
    }

    /// @notice Transfer ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the latest tracked price for a token.
    function getTrackedPrice(address token)
        external
        view
        returns (uint256 price, uint256 lastUpdated, uint256 updateCount)
    {
        PriceRecord memory r = trackedPrices[token];
        return (r.price, r.lastUpdated, r.updateCount);
    }
}
