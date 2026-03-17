// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @title DobSwapRouter
/// @notice Minimal router for dobRWA ↔ USDC swaps through the DobPegHook.
///         Users approve this router, call swap(), and receive output tokens.
contract DobSwapRouter {
    using SafeTransferLib for ERC20;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    PoolKey public poolKey;
    bool public poolKeySet;

    error PoolKeyNotSet();
    error OnlyPoolManager();

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    /// @notice Set the pool key (callable once by anyone — typically deployer).
    function setPoolKey(
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 tickSpacing,
        address hook
    ) external {
        require(!poolKeySet, "already set");
        Currency c0;
        Currency c1;
        if (tokenA < tokenB) {
            c0 = Currency.wrap(tokenA);
            c1 = Currency.wrap(tokenB);
        } else {
            c0 = Currency.wrap(tokenB);
            c1 = Currency.wrap(tokenA);
        }
        poolKey = PoolKey(c0, c1, fee, tickSpacing, IHooks(hook));
        poolKeySet = true;
    }

    /// @notice Swap exact input tokens through the DobPegHook pool.
    /// @param zeroForOne true = currency0 → currency1, false = currency1 → currency0.
    /// @param amountIn   Exact amount of input tokens.
    /// @param hookData   Optional hook data (encode RWA token address for liquidation swaps).
    /// @return amountOut The amount of output tokens received.
    function swap(
        bool zeroForOne,
        uint256 amountIn,
        bytes calldata hookData
    ) external returns (uint256 amountOut) {
        if (!poolKeySet) revert PoolKeyNotSet();

        // Transfer input tokens from user to this router
        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        ERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(msg.sender, address(this), amountIn);

        // Unlock PoolManager and execute swap inside callback
        bytes memory result = poolManager.unlock(
            abi.encode(msg.sender, zeroForOne, amountIn, hookData)
        );
        amountOut = abi.decode(result, (uint256));
    }

    /// @notice Callback from PoolManager during unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (address user, bool zeroForOne, uint256 amountIn, bytes memory hookData) =
            abi.decode(data, (address, bool, uint256, bytes));

        // Execute the swap — hook intercepts via beforeSwap + Custom Accounting
        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? uint160(4295128739 + 1)
                    : uint160(1461446703485210103287273052203988822378723970342 - 1)
            }),
            hookData
        );

        // Settle deltas created by the swap.
        // With the NoOp hook: the hook already settled output and minted ERC6909
        // for input inside beforeSwap. The router's remaining deltas are:
        //   - Negative delta on input side = router must pay (settle)
        //   - Positive delta on output side = router can take (receive)

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Settle any negative deltas (debts — router owes PoolManager)
        if (delta0 < 0) {
            ERC20 t = ERC20(Currency.unwrap(poolKey.currency0));
            poolManager.sync(poolKey.currency0);
            t.safeTransfer(address(poolManager), uint256(uint128(-delta0)));
            poolManager.settle();
        }
        if (delta1 < 0) {
            ERC20 t = ERC20(Currency.unwrap(poolKey.currency1));
            poolManager.sync(poolKey.currency1);
            t.safeTransfer(address(poolManager), uint256(uint128(-delta1)));
            poolManager.settle();
        }

        // Take any positive deltas (credits — PoolManager owes router → send to user)
        uint256 amountOut = 0;
        if (delta0 > 0) {
            amountOut = uint256(uint128(delta0));
            poolManager.take(poolKey.currency0, user, amountOut);
        }
        if (delta1 > 0) {
            amountOut = uint256(uint128(delta1));
            poolManager.take(poolKey.currency1, user, amountOut);
        }

        return abi.encode(amountOut);
    }
}
