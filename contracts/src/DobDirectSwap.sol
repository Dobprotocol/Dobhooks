// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {DobRwaVault} from "./DobRwaVault.sol";

/// @title DobDirectSwap
/// @notice Lightweight 1:1 peg swap for dUSDC ↔ USDC on chains without Uniswap V4.
///         Holds USDC reserves and swaps at exact 1:1 rate.
///         Sell: user sends dUSDC → receives USDC
///         Buy:  user sends USDC  → receives dUSDC
contract DobDirectSwap is Owned, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    ERC20 public immutable usdc;
    ERC20 public immutable dusdc; // DobRwaVault is also the dUSDC ERC20

    event Swap(address indexed user, bool dusdcToUsdc, uint256 amount);
    event Seeded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, address indexed token, uint256 amount);

    error ZeroAmount();
    error InsufficientReserves();

    constructor(address _usdc, address _dusdc, address _owner) Owned(_owner) {
        usdc = ERC20(_usdc);
        dusdc = ERC20(_dusdc);
    }

    /// @notice Swap dUSDC → USDC (1:1)
    function sellDusdc(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (usdc.balanceOf(address(this)) < amount) revert InsufficientReserves();

        dusdc.safeTransferFrom(msg.sender, address(this), amount);
        usdc.safeTransfer(msg.sender, amount);

        emit Swap(msg.sender, true, amount);
    }

    /// @notice Swap USDC → dUSDC (1:1)
    function buyDusdc(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (dusdc.balanceOf(address(this)) < amount) revert InsufficientReserves();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        dusdc.safeTransfer(msg.sender, amount);

        emit Swap(msg.sender, false, amount);
    }

    /// @notice Unified swap entry point (matches DobSwapRouter interface)
    /// @param zeroForOne true = USDC→dUSDC, false = dUSDC→USDC
    /// @param amountIn Amount to swap
    function swap(bool zeroForOne, uint256 amountIn, bytes calldata) external nonReentrant returns (uint256) {
        if (amountIn == 0) revert ZeroAmount();

        if (zeroForOne) {
            // USDC → dUSDC
            if (dusdc.balanceOf(address(this)) < amountIn) revert InsufficientReserves();
            usdc.safeTransferFrom(msg.sender, address(this), amountIn);
            dusdc.safeTransfer(msg.sender, amountIn);
            emit Swap(msg.sender, false, amountIn);
        } else {
            // dUSDC → USDC
            if (usdc.balanceOf(address(this)) < amountIn) revert InsufficientReserves();
            dusdc.safeTransferFrom(msg.sender, address(this), amountIn);
            usdc.safeTransfer(msg.sender, amountIn);
            emit Swap(msg.sender, true, amountIn);
        }

        return amountIn;
    }

    /// @notice Seed USDC reserves for redemptions
    function seedUsdc(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Seeded(msg.sender, amount);
    }

    /// @notice Seed dUSDC reserves for buys
    function seedDusdc(uint256 amount) external {
        dusdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Seeded(msg.sender, amount);
    }

    /// @notice Admin: withdraw reserves
    function withdraw(address token, uint256 amount) external onlyOwner {
        ERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    /// @notice Check USDC reserves
    function usdcReserves() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Check dUSDC reserves
    function dusdcReserves() external view returns (uint256) {
        return dusdc.balanceOf(address(this));
    }
}
