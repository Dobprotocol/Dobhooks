// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

/// @title MockRWA
/// @notice Mintable ERC-20 representing a tokenized RWA. Anyone can mint via
///         the faucet (for hackathon/demo purposes).
contract MockRWA is ERC20, Owned {
    uint256 public constant FAUCET_AMOUNT = 10e18; // 10 tokens per claim
    uint256 public constant COOLDOWN = 1 hours;

    mapping(address => uint256) public lastClaim;

    error CooldownActive();

    constructor(string memory _name, string memory _symbol, address _owner)
        ERC20(_name, _symbol, 18)
        Owned(_owner)
    {}

    /// @notice Anyone can claim free tokens (faucet). 1-hour cooldown per address.
    function faucet() external {
        if (block.timestamp - lastClaim[msg.sender] < COOLDOWN) revert CooldownActive();
        lastClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    /// @notice Admin can mint any amount (for seeding).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

/// @title MockUSDC
/// @notice Mintable mock USDC for demo. 18 decimals (simplified).
contract MockUSDC is ERC20, Owned {
    uint256 public constant FAUCET_AMOUNT = 100_000e18; // 100k USDC per claim
    uint256 public constant COOLDOWN = 1 hours;

    mapping(address => uint256) public lastClaim;

    error CooldownActive();

    constructor(address _owner) ERC20("USD Coin", "USDC", 18) Owned(_owner) {}

    function faucet() external {
        if (block.timestamp - lastClaim[msg.sender] < COOLDOWN) revert CooldownActive();
        lastClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
