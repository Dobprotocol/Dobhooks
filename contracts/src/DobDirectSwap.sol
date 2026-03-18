// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {DobRwaVault} from "./DobRwaVault.sol";

/// @title DobDirectSwap
/// @notice Lightweight 1:1 peg swap for dUSDC <> USDC on chains without Uniswap V4.
///         Holds USDC reserves and swaps at exact 1:1 rate (minus fee on sell).
///         Sell: user sends dUSDC -> receives USDC (fee applied)
///         Buy:  user sends USDC  -> receives dUSDC (no fee)
///         Includes a permissionless USDC LP pool with share-based accounting.
contract DobDirectSwap is Owned, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    ERC20 public immutable usdc;
    ERC20 public immutable dusdc; // DobRwaVault is also the dUSDC ERC20

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
    uint16 public swapFeeBps;

    /// @notice Protocol-seeded USDC reserves (separate from LP pool).
    uint256 public protocolReserveUsdc;

    /// @notice Minimum time an LP must wait before withdrawing.
    uint48 public constant MIN_LP_DURATION = 1 hours;

    /// @notice Dead shares minted on first deposit to prevent first-depositor attack.
    uint256 private constant DEAD_SHARES = 1000;

    event Swap(address indexed user, bool dusdcToUsdc, uint256 amountIn, uint256 amountOut);
    event Seeded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, address indexed token, uint256 amount);
    event UsdcDeposited(address indexed lp, uint256 amount, uint256 shares);
    event UsdcWithdrawn(address indexed lp, uint256 shares, uint256 amount);
    event SwapFeeSet(uint16 feeBps);
    event ProtocolReserveWithdrawn(address indexed to, uint256 amount);

    error ZeroAmount();
    error InsufficientReserves();
    error FeeTooHigh();
    error LPDurationNotMet();
    error InsufficientShares();

    constructor(address _usdc, address _dusdc, address _owner) Owned(_owner) {
        usdc = ERC20(_usdc);
        dusdc = ERC20(_dusdc);
    }

    /*//////////////////////////////////////////////////////////////
                           SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap dUSDC -> USDC (1:1 minus fee)
    function sellDusdc(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 amountOut;
        if (swapFeeBps > 0) {
            uint256 fee = (amount * swapFeeBps) / 10000;
            amountOut = amount - fee;
            totalLpUsdc += fee;
        } else {
            amountOut = amount;
        }

        if (usdc.balanceOf(address(this)) < amountOut) revert InsufficientReserves();

        dusdc.safeTransferFrom(msg.sender, address(this), amount);
        usdc.safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, true, amount, amountOut);
    }

    /// @notice Swap USDC -> dUSDC (1:1, no fee)
    function buyDusdc(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (dusdc.balanceOf(address(this)) < amount) revert InsufficientReserves();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        dusdc.safeTransfer(msg.sender, amount);

        emit Swap(msg.sender, false, amount, amount);
    }

    /// @notice Unified swap entry point (matches DobSwapRouter interface)
    /// @param zeroForOne true = USDC->dUSDC, false = dUSDC->USDC
    /// @param amountIn Amount to swap
    function swap(bool zeroForOne, uint256 amountIn, bytes calldata) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        if (zeroForOne) {
            // USDC -> dUSDC (no fee)
            if (dusdc.balanceOf(address(this)) < amountIn) revert InsufficientReserves();
            usdc.safeTransferFrom(msg.sender, address(this), amountIn);
            dusdc.safeTransfer(msg.sender, amountIn);
            amountOut = amountIn;
            emit Swap(msg.sender, false, amountIn, amountOut);
        } else {
            // dUSDC -> USDC (fee applied)
            if (swapFeeBps > 0) {
                uint256 fee = (amountIn * swapFeeBps) / 10000;
                amountOut = amountIn - fee;
                totalLpUsdc += fee;
            } else {
                amountOut = amountIn;
            }
            if (usdc.balanceOf(address(this)) < amountOut) revert InsufficientReserves();
            dusdc.safeTransferFrom(msg.sender, address(this), amountIn);
            usdc.safeTransfer(msg.sender, amountOut);
            emit Swap(msg.sender, true, amountIn, amountOut);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    PERMISSIONLESS USDC LP POOL
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the swap fee. Only callable by owner. Max 10%.
    function setSwapFee(uint16 feeBps) external onlyOwner {
        if (feeBps > 1000) revert FeeTooHigh();
        swapFeeBps = feeBps;
        emit SwapFeeSet(feeBps);
    }

    /// @notice Deposit USDC into the LP pool and receive shares.
    function depositUsdc(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (totalShares == 0) {
            require(amount > DEAD_SHARES, "First deposit too small");
            shares = amount - DEAD_SHARES;
            totalShares = amount;
            lpShares[address(1)] += DEAD_SHARES;
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
    function withdrawUsdc(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        if (lpShares[msg.sender] < shares) revert InsufficientShares();
        if (block.timestamp < lpDepositedAt[msg.sender] + MIN_LP_DURATION) revert LPDurationNotMet();

        amount = (shares * totalLpUsdc) / totalShares;

        uint256 available = usdc.balanceOf(address(this));
        if (amount > available) revert InsufficientReserves();

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
                      PROTOCOL RESERVE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Seed USDC reserves for redemptions (protocol reserve, no shares)
    function seedUsdc(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        protocolReserveUsdc += amount;
        emit Seeded(msg.sender, amount);
    }

    /// @notice Withdraw protocol reserve USDC. Only callable by owner.
    function withdrawProtocolReserve(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (amount > protocolReserveUsdc) revert InsufficientReserves();
        if (amount > usdc.balanceOf(address(this))) revert InsufficientReserves();

        protocolReserveUsdc -= amount;
        usdc.safeTransfer(msg.sender, amount);

        emit ProtocolReserveWithdrawn(msg.sender, amount);
    }

    /// @notice Seed dUSDC reserves for buys
    function seedDusdc(uint256 amount) external {
        dusdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Seeded(msg.sender, amount);
    }

    /// @notice Admin: withdraw non-USDC token reserves (e.g. dUSDC).
    ///         For USDC, use withdrawProtocolReserve() to protect LP pool accounting.
    function withdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(usdc), "Use withdrawProtocolReserve for USDC");
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
