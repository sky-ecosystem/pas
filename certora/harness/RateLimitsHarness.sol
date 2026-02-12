// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// RateLimitsHarness.sol -- Certora harness for RateLimits interface

pragma solidity ^0.8.24;

contract RateLimitsHarness {

    struct RateLimitData {
        uint256 maxAmount;
        uint256 slope;
        uint256 lastAmount;
        uint256 lastUpdated;
    }

    mapping(bytes32 key => RateLimitData) public rateLimitData;

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function setRateLimitData(
        bytes32 key,
        uint256 maxAmount,
        uint256 slope,
        uint256 lastAmount,
        uint256 lastUpdated
    ) external {
        rateLimitData[key] = RateLimitData(maxAmount, slope, lastAmount, lastUpdated);
    }

    function setUnlimitedRateLimitData(bytes32 key) external {
        rateLimitData[key] = RateLimitData(type(uint256).max, 0, type(uint256).max, block.timestamp);
    }

    function getRateLimitData(bytes32 key) external view returns (RateLimitData memory) {
        return rateLimitData[key];
    }

    // Mimics real RateLimits: regenerates based on slope and elapsed time
    function getCurrentRateLimit(bytes32 key) external view returns (uint256) {
        RateLimitData memory d = rateLimitData[key];
        if (d.maxAmount == type(uint256).max) {
            return type(uint256).max;
        }
        return _min(
            d.slope * (block.timestamp - d.lastUpdated) + d.lastAmount,
            d.maxAmount
        );
    }

    // --- Getters for individual struct fields (for Certora) ---

    function getMaxAmount(bytes32 key) external view returns (uint256) {
        return rateLimitData[key].maxAmount;
    }

    function getSlope(bytes32 key) external view returns (uint256) {
        return rateLimitData[key].slope;
    }

    function getLastAmount(bytes32 key) external view returns (uint256) {
        return rateLimitData[key].lastAmount;
    }

    function getLastUpdated(bytes32 key) external view returns (uint256) {
        return rateLimitData[key].lastUpdated;
    }
}
