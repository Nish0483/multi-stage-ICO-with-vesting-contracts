// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ICO_vesting.sol";
import "./Vesting.sol";

/**
 * @dev Default deploy params. To change stage count, add/remove entries in BOTH
 *      buildDefaultRounds() and buildDefaultStages() — arrays must stay the same length.
 */
library IcoDeploymentConfig {
    uint32 internal constant STAGE_INTERVAL = 30 days;

    function buildDefaultRounds()
        internal
        pure
        returns (VestingVault.RoundConfig[] memory rounds)
    {
        rounds = new VestingVault.RoundConfig[](5);
        rounds[0] = VestingVault.RoundConfig(90 days, 360 days, 1000);
        rounds[1] = VestingVault.RoundConfig(30 days, 180 days, 2000);
        rounds[2] = VestingVault.RoundConfig(15 days, 90 days, 3000);
        rounds[3] = VestingVault.RoundConfig(0, 30 days, 6000);
        rounds[4] = VestingVault.RoundConfig(0, 0, 10000);
    }

    function buildDefaultStages(
        uint32 icoStartTime,
        uint8 tokenDecimals
    ) internal pure returns (ICO.Stage[] memory stages) {
        uint256 unit = 10 ** uint256(tokenDecimals);
        stages = new ICO.Stage[](5);

        stages[0] = ICO.Stage({
            cap: uint128(50_000_000_000_000 * unit),
            sold: 0,
            price: 10e12,
            endTime: icoStartTime + STAGE_INTERVAL,
            minPurchase: 100
        });
        stages[1] = ICO.Stage({
            cap: uint128(50_000_000_000_000 * unit),
            sold: 0,
            price: 12e12,
            endTime: icoStartTime + STAGE_INTERVAL * 2,
            minPurchase: 50
        });
        stages[2] = ICO.Stage({
            cap: uint128(30_000_000_000_000 * unit),
            sold: 0,
            price: 14e12,
            endTime: icoStartTime + STAGE_INTERVAL * 3,
            minPurchase: 10
        });
        stages[3] = ICO.Stage({
            cap: uint128(30_000_000_000_000 * unit),
            sold: 0,
            price: 16e12,
            endTime: icoStartTime + STAGE_INTERVAL * 4,
            minPurchase: 10
        });
        stages[4] = ICO.Stage({
            cap: uint128(40_000_000_000_000 * unit),
            sold: 0,
            price: 18e12,
            endTime: icoStartTime + STAGE_INTERVAL * 5,
            minPurchase: 10
        });
    }
}
