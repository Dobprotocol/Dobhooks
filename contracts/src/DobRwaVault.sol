// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {DobValidatorRegistry} from "./DobValidatorRegistry.sol";

/// @title DobRwaVault
/// @notice Central RWA depository. Accepts deposits of approved ERC-20 RWA tokens,
///         queries the DobValidatorRegistry oracle for a USD valuation, and mints
///         `dobRWA` — a unified, highly liquid receipt token — to the depositor.
contract DobRwaVault is ERC20, Owned {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The DobValidatorRegistry oracle used for pricing.
    DobValidatorRegistry public immutable oracle;

    /// @notice Maximum oracle delay (seconds) before minting is paused.
    uint48 public immutable maxOracleDelay;

    /// @notice Whitelist of RWA tokens approved for deposit.
    mapping(address => bool) public approvedAssets;

    /// @notice The authorized hook address that can burn dobRWA during liquidations.
    address public hook;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AssetApproved(address indexed token);
    event AssetRemoved(address indexed token);
    event Deposited(address indexed user, address indexed rwaToken, uint256 rwaAmount, uint256 dobRwaMinted);
    event Withdrawn(address indexed to, address indexed rwaToken, uint256 dobRwaAmount, uint256 rwaAmount);
    event DobRwaBurned(address indexed from, uint256 amount);
    event HookSet(address indexed hook);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error AssetNotApproved();
    error OracleStale();
    error ZeroAmount();
    error OnlyHook();
    error InsufficientRwaBalance();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _oracle  Address of the DobValidatorRegistry.
    /// @param _maxDelay Maximum staleness window (seconds) for oracle prices.
    /// @param _owner   Protocol admin.
    constructor(address _oracle, uint48 _maxDelay, address _owner)
        ERC20("Dobprotocol RWA Index", "dobRWA", 18)
        Owned(_owner)
    {
        oracle = DobValidatorRegistry(_oracle);
        maxOracleDelay = _maxDelay;
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Approve an RWA token for vault deposits.
    function addApprovedAsset(address token) external onlyOwner {
        approvedAssets[token] = true;
        emit AssetApproved(token);
    }

    /// @notice Remove an RWA token from the approved list.
    function removeApprovedAsset(address token) external onlyOwner {
        approvedAssets[token] = false;
        emit AssetRemoved(token);
    }

    /// @notice Set the authorized hook address that can burn dobRWA.
    function setHook(address _hook) external onlyOwner {
        hook = _hook;
        emit HookSet(_hook);
    }

    /// @notice Burn dobRWA tokens. Only callable by the authorized hook
    ///         during liquidation swaps to destroy the penalty portion.
    /// @param from   Address to burn from (must have approved or be msg.sender).
    /// @param amount Amount of dobRWA to burn.
    function burn(address from, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        _burn(from, amount);
        emit DobRwaBurned(from, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         DEPOSIT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit `amount` of an approved `rwaToken` and receive `dobRWA`.
    /// @dev The caller must have approved this vault to spend `rwaToken`.
    /// @param rwaToken The ERC-20 address of the RWA token.
    /// @param amount   The amount of `rwaToken` to deposit (18-decimal).
    /// @return mintAmount The amount of `dobRWA` minted to the caller.
    function deposit(address rwaToken, uint256 amount) external returns (uint256 mintAmount) {
        if (amount == 0) revert ZeroAmount();
        if (!approvedAssets[rwaToken]) revert AssetNotApproved();

        // --- Oracle Query & Staleness Check ---
        (uint256 priceUsd, uint48 updatedAt) = oracle.getPrice(rwaToken);
        if (block.timestamp - updatedAt > maxOracleDelay) revert OracleStale();

        // --- Transfer RWA into the Vault ---
        ERC20(rwaToken).safeTransferFrom(msg.sender, address(this), amount);

        // --- Mint dobRWA ---
        // priceUsd is 18-decimal (price per 1e18 base units of rwaToken)
        // amount is 18-decimal
        // mintAmount = amount * priceUsd / 1e18
        mintAmount = (amount * priceUsd) / 1e18;

        _mint(msg.sender, mintAmount);

        emit Deposited(msg.sender, rwaToken, amount, mintAmount);
    }

    /*//////////////////////////////////////////////////////////////
                         WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn dobRWA and withdraw underlying RWA tokens at oracle price.
    ///         Only callable by the authorized hook during LP RWA claims.
    /// @param rwaToken    The ERC-20 address of the RWA token to withdraw.
    /// @param dobRwaAmount The amount of dobRWA to burn.
    /// @param to          The address to receive the RWA tokens.
    /// @return rwaAmount  The amount of RWA tokens sent to `to`.
    function withdraw(address rwaToken, uint256 dobRwaAmount, address to) external returns (uint256 rwaAmount) {
        if (msg.sender != hook) revert OnlyHook();
        if (dobRwaAmount == 0) revert ZeroAmount();
        if (!approvedAssets[rwaToken]) revert AssetNotApproved();

        // --- Oracle Query & Staleness Check ---
        (uint256 priceUsd, uint48 updatedAt) = oracle.getPrice(rwaToken);
        if (block.timestamp - updatedAt > maxOracleDelay) revert OracleStale();

        // --- Calculate RWA amount (inverse of deposit) ---
        // deposit: mintAmount = (rwaAmount * priceUsd) / 1e18
        // withdraw: rwaAmount = (dobRwaAmount * 1e18) / priceUsd
        rwaAmount = (dobRwaAmount * 1e18) / priceUsd;
        if (rwaAmount == 0) revert ZeroAmount();

        // --- Safety check: vault has enough RWA tokens ---
        if (ERC20(rwaToken).balanceOf(address(this)) < rwaAmount) revert InsufficientRwaBalance();

        // --- Burn dobRWA from vault's balance (hook transfers to vault before calling) ---
        _burn(address(this), dobRwaAmount);

        // --- Transfer RWA tokens to the recipient ---
        ERC20(rwaToken).safeTransfer(to, rwaAmount);

        emit Withdrawn(to, rwaToken, dobRwaAmount, rwaAmount);
    }
}
