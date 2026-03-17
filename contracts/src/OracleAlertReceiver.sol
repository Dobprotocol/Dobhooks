// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title OracleAlertReceiver
/// @notice Deployed on Unichain Sepolia (chain 1301).
///         Receives cross-chain callbacks from ReactiveOracleSync on Reactive Network
///         when oracle prices drop below configured thresholds or liquidation events occur.
///
/// @dev The Reactive Network delivers callbacks via its Callback Proxy contract
///      deployed on each supported destination chain. Only the Callback Proxy
///      is authorized to call the on* functions.
///
/// Partner Integration: Reactive Network (https://reactive.network)
contract OracleAlertReceiver {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event PriceAlertReceived(
        address indexed token,
        uint256 price,
        uint256 threshold,
        uint256 timestamp
    );

    event LiquidationAlertReceived(
        address indexed token,
        uint16 penaltyBps,
        uint256 cap,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                               TYPES
    //////////////////////////////////////////////////////////////*/

    struct PriceAlert {
        address token;
        uint256 price;
        uint256 threshold;
        uint256 timestamp;
    }

    struct LiquidationAlert {
        address token;
        uint16 penaltyBps;
        uint256 cap;
        uint256 timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Reactive Network's Callback Proxy on Unichain Sepolia
    address public immutable callbackProxy;

    /// @notice Contract owner
    address public owner;

    /// @notice All received price alerts
    PriceAlert[] public priceAlerts;

    /// @notice All received liquidation alerts
    LiquidationAlert[] public liquidationAlerts;

    /// @notice Token → latest price alert
    mapping(address => PriceAlert) public latestPriceAlert;

    /// @notice Token → latest liquidation alert
    mapping(address => LiquidationAlert) public latestLiquidationAlert;

    /// @notice Total callbacks received
    uint256 public totalCallbacks;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCallbackProxy() {
        require(msg.sender == callbackProxy, "Only callback proxy");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _callbackProxy Reactive Network's Callback Proxy address on Unichain Sepolia
    constructor(address _callbackProxy) {
        callbackProxy = _callbackProxy;
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                        CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by Reactive Network's Callback Proxy when a price drops below threshold.
    /// @param token     The RWA token address
    /// @param price     The current oracle price (18-decimal)
    /// @param threshold The configured alert threshold
    function onPriceAlert(
        address token,
        uint256 price,
        uint256 threshold
    ) external onlyCallbackProxy {
        PriceAlert memory alert = PriceAlert({
            token: token,
            price: price,
            threshold: threshold,
            timestamp: block.timestamp
        });

        priceAlerts.push(alert);
        latestPriceAlert[token] = alert;
        totalCallbacks++;

        emit PriceAlertReceived(token, price, threshold, block.timestamp);
    }

    /// @notice Called by Reactive Network's Callback Proxy when liquidation is enabled.
    /// @param token      The RWA token address
    /// @param penaltyBps Liquidation penalty in basis points
    /// @param cap        Maximum amount that can be liquidated
    function onLiquidationEnabled(
        address token,
        uint16 penaltyBps,
        uint256 cap
    ) external onlyCallbackProxy {
        LiquidationAlert memory alert = LiquidationAlert({
            token: token,
            penaltyBps: penaltyBps,
            cap: cap,
            timestamp: block.timestamp
        });

        liquidationAlerts.push(alert);
        latestLiquidationAlert[token] = alert;
        totalCallbacks++;

        emit LiquidationAlertReceived(token, penaltyBps, cap, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the total number of price alerts received.
    function getPriceAlertCount() external view returns (uint256) {
        return priceAlerts.length;
    }

    /// @notice Get the total number of liquidation alerts received.
    function getLiquidationAlertCount() external view returns (uint256) {
        return liquidationAlerts.length;
    }

    /// @notice Get a range of recent price alerts.
    function getRecentPriceAlerts(uint256 count)
        external
        view
        returns (PriceAlert[] memory)
    {
        uint256 total = priceAlerts.length;
        if (count > total) count = total;
        PriceAlert[] memory result = new PriceAlert[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = priceAlerts[total - count + i];
        }
        return result;
    }

    /// @notice Get a range of recent liquidation alerts.
    function getRecentLiquidationAlerts(uint256 count)
        external
        view
        returns (LiquidationAlert[] memory)
    {
        uint256 total = liquidationAlerts.length;
        if (count > total) count = total;
        LiquidationAlert[] memory result = new LiquidationAlert[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = liquidationAlerts[total - count + i];
        }
        return result;
    }

    /// @notice Transfer ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }
}
