// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {RWAToken, DobTokenFactory} from "../src/DobTokenFactory.sol";
import {DobValidatorRegistry} from "../src/DobValidatorRegistry.sol";
import {DobRwaVault} from "../src/DobRwaVault.sol";
import {MockUSDC} from "../src/RWAFaucet.sol";

contract RWATokenTest is Test {
    RWAToken public dct;
    MockUSDC public usdc;
    address public owner = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC(owner);
        dct = new RWAToken("Datacenter Token", "DCT", 10_000e18, owner, address(usdc));

        // Configure sale at $100 per token
        dct.configureSale(100e18, true);

        // Give alice USDC
        usdc.mint(alice, 1_000_000e18);
    }

    function testMetadata() public view {
        assertEq(dct.name(), "Datacenter Token");
        assertEq(dct.symbol(), "DCT");
        assertEq(dct.decimals(), 18);
        assertEq(dct.totalSupply(), 10_000e18);
        assertEq(dct.balanceOf(owner), 10_000e18);
    }

    function testBuyTokens() public {
        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);

        // Buy 10 tokens at $100 each = $1,000 USDC
        dct.buyTokens(10e18);
        vm.stopPrank();

        assertEq(dct.balanceOf(alice), 10e18);
        assertEq(dct.balanceOf(owner), 9_990e18);
        // 10 * 100 = 1000 USDC transferred to treasury (owner)
        assertEq(usdc.balanceOf(owner), 1_000e18);
        assertEq(usdc.balanceOf(alice), 999_000e18);
    }

    function testBuyTokensFractional() public {
        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);

        // Buy 0.5 tokens = $50 USDC
        dct.buyTokens(0.5e18);
        vm.stopPrank();

        assertEq(dct.balanceOf(alice), 0.5e18);
        assertEq(usdc.balanceOf(owner), 50e18);
    }

    function testBuyTokensRevertsWhenSaleInactive() public {
        dct.configureSale(100e18, false);

        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);
        vm.expectRevert(RWAToken.SaleNotActive.selector);
        dct.buyTokens(1e18);
        vm.stopPrank();
    }

    function testBuyTokensRevertsZeroAmount() public {
        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);
        vm.expectRevert(RWAToken.ZeroAmount.selector);
        dct.buyTokens(0);
        vm.stopPrank();
    }

    function testBuyTokensRevertsInsufficientSupply() public {
        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);
        vm.expectRevert(RWAToken.InsufficientTokensForSale.selector);
        dct.buyTokens(10_001e18); // more than supply
        vm.stopPrank();
    }

    function testPauseTransfers() public {
        // Give alice some tokens first
        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);
        dct.buyTokens(10e18);
        vm.stopPrank();

        // Owner pauses
        dct.setPaused(true);

        // Alice can't transfer
        vm.prank(alice);
        vm.expectRevert(RWAToken.TransfersPaused.selector);
        dct.transfer(bob, 5e18);

        // Owner unpauses
        dct.setPaused(false);

        // Alice can transfer now
        vm.prank(alice);
        dct.transfer(bob, 5e18);
        assertEq(dct.balanceOf(bob), 5e18);
    }

    function testSetTreasury() public {
        dct.setTreasury(bob);

        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);
        dct.buyTokens(1e18);
        vm.stopPrank();

        // USDC goes to new treasury
        assertEq(usdc.balanceOf(bob), 100e18);
        assertEq(usdc.balanceOf(owner), 0);
    }

    function testConfigureSaleOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        dct.configureSale(200e18, true);
    }
}

contract RWATokenVaultIntegrationTest is Test {
    RWAToken public dct;
    MockUSDC public usdc;
    DobValidatorRegistry public registry;
    DobRwaVault public vault;

    address public owner = address(this);
    address public alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockUSDC(owner);
        registry = new DobValidatorRegistry(owner);
        vault = new DobRwaVault(address(registry), 1 days, owner);

        dct = new RWAToken("Datacenter Token", "DCT", 10_000e18, owner, address(usdc));
        dct.configureSale(100e18, true);

        // Set oracle price and approve in vault
        registry.setPrice(address(dct), 100e18); // $100 per token
        vault.addApprovedAsset(address(dct));

        // Give alice USDC
        usdc.mint(alice, 1_000_000e18);
    }

    function testFullFlow_BuyAndDeposit() public {
        // 1. Alice buys 10 DCT with USDC
        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);
        dct.buyTokens(10e18);
        assertEq(dct.balanceOf(alice), 10e18);

        // 2. Alice deposits DCT into vault to get dobRWA
        dct.approve(address(vault), type(uint256).max);
        uint256 dobRwaMinted = vault.deposit(address(dct), 10e18);
        vm.stopPrank();

        // 10 tokens * $100 price = $1,000 dobRWA
        assertEq(dobRwaMinted, 1_000e18);
        assertEq(vault.balanceOf(alice), 1_000e18);
        assertEq(dct.balanceOf(alice), 0);
        assertEq(dct.balanceOf(address(vault)), 10e18);
    }

    function testFullFlow_PartialDeposit() public {
        vm.startPrank(alice);
        usdc.approve(address(dct), type(uint256).max);
        dct.buyTokens(100e18); // buy 100 tokens

        dct.approve(address(vault), type(uint256).max);
        uint256 dobRwa = vault.deposit(address(dct), 25e18); // deposit 25
        vm.stopPrank();

        assertEq(dobRwa, 2_500e18); // 25 * $100
        assertEq(dct.balanceOf(alice), 75e18); // 75 remaining
    }
}

contract DobTokenFactoryTest is Test {
    DobTokenFactory public factory;
    MockUSDC public usdc;
    DobValidatorRegistry public registry;
    DobRwaVault public vault;

    address public owner = address(this);
    address public alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockUSDC(owner);
        registry = new DobValidatorRegistry(owner);
        vault = new DobRwaVault(address(registry), 1 days, owner);

        factory = new DobTokenFactory(address(usdc), owner);

        // Transfer ownership so factory can set prices and approve assets
        registry.transferOwnership(address(factory));
        vault.transferOwnership(address(factory));

        factory.setRegistry(address(registry));
        factory.setVault(address(vault));

        usdc.mint(alice, 1_000_000e18);
    }

    function testCreateAsset() public {
        address token = factory.createAsset(
            "Datacenter Token", "DCT", 10_000e18, 100e18, 100e18
        );

        // Token created
        RWAToken dct = RWAToken(token);
        assertEq(dct.name(), "Datacenter Token");
        assertEq(dct.symbol(), "DCT");
        assertEq(dct.decimals(), 18);
        assertEq(dct.totalSupply(), 10_000e18);
        assertEq(dct.balanceOf(address(factory)), 10_000e18);
        assertTrue(dct.saleActive());
        assertEq(dct.salePrice(), 100e18);

        // Oracle price set
        (uint256 price,) = registry.getPrice(token);
        assertEq(price, 100e18);

        // Vault approved
        assertTrue(vault.approvedAssets(token));

        // Factory tracks the asset
        assertEq(factory.assetCount(), 1);
        address[] memory tokens = factory.getAssets();
        assertEq(tokens[0], token);
    }

    function testCreateMultipleAssets() public {
        factory.createAsset("DCT", "DCT", 10_000e18, 100e18, 100e18);
        factory.createAsset("SFT", "SFT", 20_000e18, 50e18, 50e18);
        factory.createAsset("RET", "RET", 4_000e18, 250e18, 250e18);
        factory.createAsset("PWG", "PWG", 15_000e18, 75e18, 75e18);

        assertEq(factory.assetCount(), 4);
    }

    function testBuyFromFactoryCreatedToken() public {
        address token = factory.createAsset(
            "Datacenter Token", "DCT", 10_000e18, 100e18, 100e18
        );

        RWAToken dct = RWAToken(token);

        // Alice buys 5 tokens
        vm.startPrank(alice);
        usdc.approve(token, type(uint256).max);
        dct.buyTokens(5e18);
        vm.stopPrank();

        assertEq(dct.balanceOf(alice), 5e18);
        assertEq(dct.balanceOf(address(factory)), 9_995e18);
        // 5 * $100 = $500 USDC to factory (treasury)
        assertEq(usdc.balanceOf(address(factory)), 500e18);
    }

    function testCreateAssetRevertsWithoutRegistry() public {
        DobTokenFactory bare = new DobTokenFactory(address(usdc), owner);
        bare.setVault(address(vault));
        vm.expectRevert(DobTokenFactory.RegistryNotSet.selector);
        bare.createAsset("X", "X", 100e18, 1e18, 1e18);
    }

    function testCreateAssetRevertsWithoutVault() public {
        DobTokenFactory bare = new DobTokenFactory(address(usdc), owner);
        bare.setRegistry(address(registry));
        vm.expectRevert(DobTokenFactory.VaultNotSet.selector);
        bare.createAsset("X", "X", 100e18, 1e18, 1e18);
    }

    function testCreateAssetOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        factory.createAsset("X", "X", 100e18, 1e18, 1e18);
    }

    function testFullFlowWithFactory() public {
        // 1. Factory creates asset
        address token = factory.createAsset(
            "Datacenter Token", "DCT", 10_000e18, 100e18, 100e18
        );

        // 2. Alice buys tokens with USDC
        vm.startPrank(alice);
        usdc.approve(token, type(uint256).max);
        RWAToken(token).buyTokens(10e18);

        // 3. Alice deposits into vault
        RWAToken(token).approve(address(vault), type(uint256).max);
        uint256 dobRwa = vault.deposit(token, 10e18);
        vm.stopPrank();

        // 10 tokens * $100 = $1,000 dobRWA
        assertEq(dobRwa, 1_000e18);
        assertEq(vault.balanceOf(alice), 1_000e18);
    }
}
