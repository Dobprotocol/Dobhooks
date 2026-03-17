// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @title RWAToken
/// @notice ERC-20 participation token for a tokenized real-world asset.
///         Mirrors the structure from Dobprotocol's distribution-contracts
///         (ParticipationToken) but simplified for the hackathon.
///
///         Key properties:
///         - Fixed supply minted at creation (like ParticipationToken.mint_single_owner)
///         - Supports a sale price in USDC so anyone can buy tokens
///         - Owner (Dobprotocol) can pause/unpause transfers
///         - 18-decimal tokens (compatible with DobRwaVault)
contract RWAToken is ERC20, Owned {
    using SafeTransferLib for ERC20;

    bool public paused;
    bool public saleActive;
    uint256 public salePrice;     // USDC per 1e18 token units (18-decimal)
    ERC20 public immutable usdc;
    address public treasury;

    event SaleConfigured(uint256 price, bool active);
    event TokensPurchased(address indexed buyer, uint256 amount, uint256 usdcPaid);
    event Paused(bool status);

    error TransfersPaused();
    error SaleNotActive();
    error InsufficientTokensForSale();
    error ZeroAmount();

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _owner,
        address _usdc
    ) ERC20(_name, _symbol, 18) Owned(_owner) {
        usdc = ERC20(_usdc);
        treasury = _owner;
        _mint(_owner, _totalSupply);
    }

    /// @notice Configure the token sale. Owner sets price and activates.
    /// @param _price USDC per 1e18 token units (e.g., 100e18 = $100/token)
    /// @param _active Whether the sale is active
    function configureSale(uint256 _price, bool _active) external onlyOwner {
        salePrice = _price;
        saleActive = _active;
        emit SaleConfigured(_price, _active);
    }

    /// @notice Set the treasury address that receives USDC from sales.
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /// @notice Buy tokens with USDC. Tokens come from owner's balance.
    /// @param amount Amount of tokens to buy (18-decimal, e.g., 5e18 = 5 tokens).
    function buyTokens(uint256 amount) external {
        if (!saleActive) revert SaleNotActive();
        if (amount == 0) revert ZeroAmount();

        uint256 ownerBal = balanceOf[owner];
        if (ownerBal < amount) revert InsufficientTokensForSale();

        // salePrice is per 1e18 units, so cost = amount * salePrice / 1e18
        uint256 usdcCost = (amount * salePrice) / 1e18;

        // Transfer USDC from buyer to treasury
        usdc.safeTransferFrom(msg.sender, treasury, usdcCost);

        // Transfer tokens from owner to buyer
        balanceOf[owner] -= amount;
        unchecked { balanceOf[msg.sender] += amount; }
        emit Transfer(owner, msg.sender, amount);

        emit TokensPurchased(msg.sender, amount, usdcCost);
    }

    /// @notice Pause/unpause transfers.
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (paused) revert TransfersPaused();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (paused) revert TransfersPaused();
        return super.transferFrom(from, to, amount);
    }
}

/// @title DobTokenFactory
/// @notice Factory that creates RWA tokens and registers them with the oracle.
///         Mirrors Token Studio functionality for the hackathon.
///
///         Flow: Dobprotocol calls createAsset() which:
///         1. Deploys an RWAToken with fixed supply
///         2. Sets the oracle price in DobValidatorRegistry
///         3. Approves the token in DobRwaVault
///         4. Configures the sale price
contract DobTokenFactory is Owned {
    struct AssetInfo {
        address token;
        string  name;
        string  symbol;
        uint256 totalSupply;
        uint256 oraclePrice;
        uint256 salePrice;
        uint256 createdAt;
    }

    address public immutable usdc;
    address public registry;
    address public vault;

    AssetInfo[] public assets;
    mapping(address => uint256) public tokenIndex; // token address -> index in assets array

    event AssetCreated(
        address indexed token,
        string name,
        string symbol,
        uint256 totalSupply,
        uint256 oraclePrice,
        uint256 salePrice
    );

    error RegistryNotSet();
    error VaultNotSet();

    constructor(address _usdc, address _owner) Owned(_owner) {
        usdc = _usdc;
    }

    function setRegistry(address _registry) external onlyOwner { registry = _registry; }
    function setVault(address _vault) external onlyOwner { vault = _vault; }

    /// @notice Create a new RWA token with full setup.
    /// @param name        Token name (e.g., "Datacenter Token")
    /// @param symbol      Token symbol (e.g., "DCT")
    /// @param totalSupply Total supply in 18-decimal (e.g., 10_000e18 = 10,000 tokens)
    /// @param oraclePrice Oracle price per 1e18 token units in 18-decimal USD
    /// @param salePrice   Sale price per 1e18 token units in 18-decimal USDC
    function createAsset(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        uint256 oraclePrice,
        uint256 salePrice
    ) external onlyOwner returns (address token) {
        if (registry == address(0)) revert RegistryNotSet();
        if (vault == address(0)) revert VaultNotSet();

        // 1. Deploy token
        RWAToken rwa = new RWAToken(name, symbol, totalSupply, address(this), usdc);
        token = address(rwa);

        // 2. Set oracle price
        IDobRegistry(registry).setPrice(token, oraclePrice);

        // 3. Approve in vault
        IDobVault(vault).addApprovedAsset(token);

        // 4. Configure sale
        rwa.configureSale(salePrice, true);

        // 5. Store info
        tokenIndex[token] = assets.length;
        assets.push(AssetInfo({
            token: token,
            name: name,
            symbol: symbol,
            totalSupply: totalSupply,
            oraclePrice: oraclePrice,
            salePrice: salePrice,
            createdAt: block.timestamp
        }));

        emit AssetCreated(token, name, symbol, totalSupply, oraclePrice, salePrice);
    }

    /// @notice Get total number of created assets.
    function assetCount() external view returns (uint256) { return assets.length; }

    /// @notice Get all asset addresses.
    function getAssets() external view returns (address[] memory tokens) {
        tokens = new address[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            tokens[i] = assets[i].token;
        }
    }
}

interface IDobRegistry {
    function setPrice(address token, uint256 priceUsd) external;
}

interface IDobVault {
    function addApprovedAsset(address token) external;
}
