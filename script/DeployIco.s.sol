// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ICO} from "../src/ICO_vesting.sol";
import {VestingVault} from "../src/Vesting.sol";
import {IcoDeploymentConfig} from "../src/IcoDeploymentConfig.sol";

/**
 * @title DeployIco
 * @notice Deploy VestingVault + ICO with matching stage/round config from IcoDeploymentConfig.
 *
 * Env vars (optional overrides):
 *   ICO_TOKEN       — ERC20 being sold (required)
 *   ICO_START_TIME  — unix timestamp (default: block.timestamp + 1 days)
 *   VERIFIER        — KYC verifier address (default: msg.sender)
 *   NATIVE_FEED     — Chainlink feed for native token
 *   USDT            — USDT (or other ERC20) payment token address
 *   USDT_FEED       — Chainlink feed for USDT
 */
contract DeployIco is Script {
    function run() external {
        address icoToken = vm.envAddress("ICO_TOKEN");
        uint32 startTime = uint32(
            vm.envOr("ICO_START_TIME", block.timestamp + 1 days)
        );
        address verifier = vm.envOr("VERIFIER", msg.sender);
        address nativeFeed = vm.envAddress("NATIVE_FEED");
        address usdt = vm.envAddress("USDT");
        address usdtFeed = vm.envAddress("USDT_FEED");

        uint8 tokenDecimals = IERC20Metadata(icoToken).decimals();

        VestingVault.RoundConfig[] memory rounds =
            IcoDeploymentConfig.buildDefaultRounds();
        ICO.Stage[] memory stages =
            IcoDeploymentConfig.buildDefaultStages(startTime, tokenDecimals);

        vm.startBroadcast();

        VestingVault vestingVault = new VestingVault(icoToken, rounds);

        ICO.PaymentTokenConfig[] memory paymentConfigs =
            new ICO.PaymentTokenConfig[](2);
        paymentConfigs[0] = ICO.PaymentTokenConfig(address(0), nativeFeed);
        paymentConfigs[1] = ICO.PaymentTokenConfig(usdt, usdtFeed);

        ICO ico = new ICO(
            icoToken,
            startTime,
            address(vestingVault),
            verifier,
            paymentConfigs,
            stages
        );

        vestingVault.grantRole(vestingVault.ALLOCATOR_ROLE(), address(ico));

        vm.stopBroadcast();

        console2.log("VestingVault", address(vestingVault));
        console2.log("ICO", address(ico));
        console2.log("Stages / rounds", stages.length);
        console2.log("ICO end time", ico.icoEndTime());
    }
}
