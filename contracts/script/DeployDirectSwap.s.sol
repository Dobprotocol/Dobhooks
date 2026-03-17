// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DobDirectSwap} from "../src/DobDirectSwap.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Deploy DobDirectSwap on any chain (designed for Robinhood Testnet).
///
/// Usage:
///   source .env
///   forge script script/DeployDirectSwap.s.sol:DeployDirectSwap \
///     --rpc-url $ROBINHOOD_RPC --broadcast -vvv
contract DeployDirectSwap is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envAddress("USDC");
        address vault = vm.envAddress("VAULT");

        console2.log("Deployer:", deployer);
        console2.log("USDC:", usdc);
        console2.log("Vault (dUSDC):", vault);

        vm.startBroadcast(pk);

        DobDirectSwap directSwap = new DobDirectSwap(usdc, vault, deployer);
        console2.log("DobDirectSwap:", address(directSwap));

        // Seed with USDC if deployer has balance
        uint256 usdcBal = ERC20(usdc).balanceOf(deployer);
        if (usdcBal > 0) {
            uint256 seedAmount = usdcBal > 100_000e18 ? 100_000e18 : usdcBal / 2;
            ERC20(usdc).approve(address(directSwap), seedAmount);
            directSwap.seedUsdc(seedAmount);
            console2.log("Seeded USDC:", seedAmount / 1e18);
        }

        vm.stopBroadcast();
    }
}
