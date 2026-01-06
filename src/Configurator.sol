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
    function cBeamsForRBeams(address, address) external view returns (uint256);
    function getInitRateLimits(bytes32, address) external view returns (uint256, uint256);
    function isControllerActionEnabled(bytes32, address) external view returns (bool);
}

contract Configurator {

    // --- Storage variables ---

    mapping(address usr => uint256 allowed) public wards;
    mapping(address usr => uint256 allowed) public bud;
    mapping(address rBeam => mapping(bytes32 key => uint256 timestamp)) public zzz;

    // --- Immutables ---

    BeamStateLike public immutable beamState;

    // --- Constants ---

    uint256 internal constant WAD = 10**18;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event SetRateLimit(address indexed rBeam, bytes32 indexed key, uint256 maxAmount, uint256 slope);

    // --- Modifiers ---

    modifier auth() {
        require(wards[msg.sender] == 1, "Configurator/not-authorized");
        _;
    }

    modifier cBeamsForRBeams(address rBeam) {
        require(beamState.cBeamsForRBeams(rBeam, msg.sender) == 1, "Configurator/not-authorized-cBeam");
        _;
    }

    // --- Constructor ---

    constructor(address beamState_) {
        require(beamState_ != address(0), "Configurator/null-beamState");
        beamState = BeamStateLike(beamState_);
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Internal functions ---

    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    // --- Admin functions ---

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function kiss(address usr) external auth {
        bud[usr] = 1;
        emit Kiss(usr);
    }

    function diss(address usr) external auth {
        bud[usr] = 0;
        emit Diss(usr);
    }

    // cBeams functions
   
    function setRateLimit(address rBeam, bytes32 key, uint256 maxAmount, uint256 slope) external cBeamsForRBeams(rBeam) {
        (uint256 defMaxAmount, uint256 defSlope) = beamState.getInitRateLimits(key, rBeam);
        if (defMaxAmount == type(uint256).max && defSlope == 0) {
            RateLimitsLike(rBeam).setUnlimitedRateLimitData(key);
            emit SetRateLimit(rBeam, key, type(uint256).max, 0);
        } else {
            RateLimitsLike.RateLimitData memory current = RateLimitsLike(rBeam).getRateLimitData(key);
            bool safe = maxAmount <= defMaxAmount && slope <= defSlope || maxAmount <= current.maxAmount && slope <= current.slope;
            uint256 maxChange = beamState.getMaxChange(rBeam);
            require(safe || block.timestamp >= zzz[rBeam][key] + beamState.getHop(rBeam), "Configurator/increment-too-soon");
            require(safe || maxAmount <= current.maxAmount * maxChange / WAD, "Configurator/maxChange-maxAmount"); // maxChange always >= WAD
            require(safe || slope <= current.slope * maxChange / WAD, "Configurator/maxChange-slope");
            if (maxAmount >= current.maxAmount || slope >= current.slope) {
                zzz[rBeam][key] = block.timestamp;
            }
            uint256 lastAmount = RateLimitsLike(rBeam).getCurrentRateLimit(key);
            RateLimitsLike(rBeam).setRateLimitData(key, maxAmount, slope, _min(maxAmount, lastAmount), block.timestamp);
            emit SetRateLimit(rBeam, key, maxAmount, slope);
        }
    }

    function callControllerAction(address rBeam, bytes calldata data) external cBeamsForRBeams(rBeam) returns (bytes memory ret) {
        require(beamState.isControllerActionEnabled(keccak256(data), rBeam), "Configurator/not-valid-data");
        bool ok;
        (ok, ret) = rBeam.call(data);
        require(ok, "Configurator/call-failed");
    }
}
