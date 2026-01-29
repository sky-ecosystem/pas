// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.24;

interface BeamStateLike {
    function controllersCBeams(address, address) external view returns (uint256);
    function rateLimitsCBeams(address, address) external view returns (uint256);
    function stopped() external view returns (bool);
    function getHop(address) external view returns (uint256);
    function getMaxChange(address) external view returns (uint256);
    function getInitRateLimits(bytes32, address) external view returns (uint256, uint256);
    function isControllerActionEnabled(bytes32, address) external view returns (bool);
}

interface RateLimitsLike {
    struct RateLimitData {
        uint256 maxAmount;
        uint256 slope;
        uint256 lastAmount;
        uint256 lastUpdated;
    }

    function getRateLimitData(bytes32) external view returns (RateLimitData memory);
    function getCurrentRateLimit(bytes32) external view returns (uint256);
    function setRateLimitData(bytes32, uint256, uint256, uint256, uint256) external;
    function setUnlimitedRateLimitData(bytes32) external;
}

contract Configurator {

    // --- Storage variables ---

    mapping(address rateLimits => mapping(bytes32 key => uint256 timestamp)) public zzz;

    // --- Immutables ---

    BeamStateLike public immutable beamState;

    // --- Constants ---

    uint256 internal constant WAD = 10**18;

    // --- Events ---

    event SetRateLimit(address indexed rateLimits, bytes32 indexed key, uint256 maxAmount, uint256 slope);
    event CallControllerAction(address indexed controller, bytes data);

    // --- Modifiers ---

    modifier notStopped() {
        require(!beamState.stopped(), "Configurator/stopped");
        _;
    }

    modifier authController(address controller) {
        require(beamState.controllersCBeams(controller, msg.sender) == 1, "Configurator/not-authorized-controller-cBeam");
        _;
    }

    modifier authRateLimits(address rateLimits) {
        require(beamState.rateLimitsCBeams(rateLimits, msg.sender) == 1, "Configurator/not-authorized-ratelimits-cBeam");
        _;
    }

    // --- Constructor ---

    constructor(address beamState_) {
        beamState = BeamStateLike(beamState_);
    }

    // --- Internal functions ---

    function _max(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x > y ? x : y;
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    // cBeams functions
   
    function setRateLimit(address rateLimits, bytes32 key, uint256 maxAmount, uint256 slope) external notStopped authRateLimits(rateLimits) {
        (uint256 defMaxAmount, uint256 defSlope) = beamState.getInitRateLimits(key, rateLimits);
        if (defMaxAmount == type(uint256).max && defSlope == 0) {
            require(maxAmount == type(uint256).max && slope == 0, "Configurator/unlimited-incorrect-params");
            RateLimitsLike(rateLimits).setUnlimitedRateLimitData(key);
            emit SetRateLimit(rateLimits, key, type(uint256).max, 0);
        } else {
            RateLimitsLike.RateLimitData memory current = RateLimitsLike(rateLimits).getRateLimitData(key);
            uint256 maxChange = beamState.getMaxChange(rateLimits);

            // Ceiling is the max of (current * maxChange) and default
            require(maxAmount <= _max(current.maxAmount * maxChange / WAD, defMaxAmount), "Configurator/exceeds-max-amount");
            require(slope <= _max(current.slope * maxChange / WAD, defSlope), "Configurator/exceeds-max-slope");

            // Any increase requires hop
            if (maxAmount > current.maxAmount || slope > current.slope) {
                require(block.timestamp >= zzz[rateLimits][key] + beamState.getHop(rateLimits), "Configurator/increment-too-soon");
                zzz[rateLimits][key] = block.timestamp;
            }

            // Note that the initial capacity for a new key will be 0 (which might differ from previous usages)
            uint256 lastAmount = RateLimitsLike(rateLimits).getCurrentRateLimit(key);
            RateLimitsLike(rateLimits).setRateLimitData(key, maxAmount, slope, _min(maxAmount, lastAmount), block.timestamp);
            emit SetRateLimit(rateLimits, key, maxAmount, slope);
        }
    }

    function callControllerAction(address controller, bytes calldata data) external notStopped authController(controller) returns (bytes memory ret) {
        require(beamState.isControllerActionEnabled(keccak256(data), controller), "Configurator/not-valid-data");
        bool ok;
        (ok, ret) = controller.call(data);
        require(ok, "Configurator/call-failed");
        emit CallControllerAction(controller, data);
    }
}
