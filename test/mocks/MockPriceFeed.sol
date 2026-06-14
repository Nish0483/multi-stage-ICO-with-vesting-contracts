// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/AggregatorV3Interface.sol";

contract MockPriceFeed is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _price;
    uint80 private _roundId = 1;
    uint256 private _startedAt; // If 0, returns current block.timestamp
    uint256 private _updatedAt; // If 0, returns current block.timestamp
    uint80 private _answeredInRound = 1;

    constructor(uint8 decimals_, int256 price_) {
        _decimals = decimals_;
        _price = price_;
        // Leave timestamps as 0 to stay "fresh" by default (returning block.timestamp)
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            _roundId,
            _price,
            _startedAt == 0 ? block.timestamp : _startedAt,
            _updatedAt == 0 ? block.timestamp : _updatedAt,
            _answeredInRound
        );
    }

    function description() external pure override returns (string memory) {
        return "Mock Price Feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function updatePrice(int256 newPrice) external {
        _price = newPrice;
        // Keep it fresh unless manually overridden via updateRoundData
        _updatedAt = 0; 
    }

    /**
     * @dev Allows tests to manually simulate stale or invalid data.
     * Use a non-zero value to lock the timestamp.
     */
    function updateRoundData(
        uint80 roundId_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _roundId = roundId_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }
}
