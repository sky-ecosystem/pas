// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

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

interface BeamStateLike {
    function getHop(address) external view returns (uint256);
    function getMaxChange(address) external view returns (uint256);
    function pauCBeams(address, address) external view returns (uint256);
    function getInitRateLimits(bytes32, address) external view returns (uint256, uint256);
    function isControllerActionEnabled(bytes32, address) external view returns (bool);
}

contract Configurator {

    // --- Storage variables ---

    mapping(address pau => mapping(bytes32 key => uint256 timestamp)) public zzz;

    // --- Immutables ---

    BeamStateLike public immutable beamState;

    // --- Constants ---

    uint256 internal constant WAD = 10**18;

    // --- Events ---

    event SetRateLimit(address indexed pau, bytes32 indexed key, uint256 maxAmount, uint256 slope);

    // --- Modifiers ---

    modifier auth(address pau) {
        require(beamState.pauCBeams(pau, msg.sender) == 1, "Configurator/not-authorized-cBeam");
        _;
    }

    // --- Constructor ---

    constructor(address beamState_) {
        beamState = BeamStateLike(beamState_);
    }

    // --- Internal functions ---

    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    // cBeams functions
   
    function setRateLimit(address pau, bytes32 key, uint256 maxAmount, uint256 slope) external auth(pau) {
        (uint256 defMaxAmount, uint256 defSlope) = beamState.getInitRateLimits(key, pau);
        if (defMaxAmount == type(uint256).max && defSlope == 0) {
            RateLimitsLike(pau).setUnlimitedRateLimitData(key);
            emit SetRateLimit(pau, key, type(uint256).max, 0);
        } else {
            RateLimitsLike.RateLimitData memory current = RateLimitsLike(pau).getRateLimitData(key);
            bool safe = maxAmount <= defMaxAmount && slope <= defSlope || maxAmount <= current.maxAmount && slope <= current.slope;
            uint256 maxChange = beamState.getMaxChange(pau);
            require(safe || block.timestamp >= zzz[pau][key] + beamState.getHop(pau), "Configurator/increment-too-soon");
            require(safe || maxAmount <= current.maxAmount * maxChange / WAD, "Configurator/maxChange-maxAmount"); // maxChange always >= WAD
            require(safe || slope <= current.slope * maxChange / WAD, "Configurator/maxChange-slope");
            if (maxAmount >= current.maxAmount || slope >= current.slope) {
                zzz[pau][key] = block.timestamp;
            }
            uint256 lastAmount = RateLimitsLike(pau).getCurrentRateLimit(key);
            RateLimitsLike(pau).setRateLimitData(key, maxAmount, slope, _min(maxAmount, lastAmount), block.timestamp);
            emit SetRateLimit(pau, key, maxAmount, slope);
        }
    }

    function callControllerAction(address pau, bytes calldata data) external auth(pau) returns (bytes memory ret) {
        require(beamState.isControllerActionEnabled(keccak256(data), pau), "Configurator/not-valid-data");
        bool ok;
        (ok, ret) = pau.call(data);
        require(ok, "Configurator/call-failed");
    }
}
