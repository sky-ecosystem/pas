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

interface ATWLStateLike {
    function govOps(address, address) external view returns (uint256);
    function getInitRateLimits(bytes32, address) external view returns (uint256, uint256);
    function isControllerActionEnabled(bytes32, address) external view returns (bool);
}

contract Configurator {

    // --- Storage variables ---

    mapping(address usr => uint256 allowed) public wards;
    mapping(address usr => uint256 allowed) public bud;
    mapping(address pau => mapping(bytes32 key => uint256 timestamp)) public zzz;
    uint256 public hop;
    uint256 public maxChange;

    // --- Immutables ---

    ATWLStateLike public immutable atwlState;

    // --- Constants ---

    uint256 internal constant WAD = 10**18;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event SetRateLimit(address indexed pau, bytes32 indexed key, uint256 maxAmount, uint256 slope);

    // --- Modifiers ---

    modifier auth() {
        require(wards[msg.sender] == 1, "Configurator/not-authorized");
        _;
    }

    modifier govOps(address pau) {
        require(atwlState.govOps(pau, msg.sender) == 1, "Configurator/not-authorized-govOps");
        _;
    }

    // --- Constructor ---

    constructor(address atwlState_) {
        require(atwlState_ != address(0), "Configurator/null-atwlState");
        atwlState = ATWLStateLike(atwlState_);
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

    function file(bytes32 what, uint256 data) external auth {
        if (what == "hop") {
            hop = data;
        } else if (what == "maxChange") {
            require(data >= WAD, "Configurator/maxChange-below-1x");
            maxChange = data;
        } else {
            revert("Configurator/file-unrecognized-param");
        }
        emit File(what, data);
    }

    // GovOps functions
   
    function setRateLimit(address pau, bytes32 key, uint256 maxAmount, uint256 slope) external govOps(pau) {
        (uint256 defMaxAmount, uint256 defSlope) = atwlState.getInitRateLimits(key, pau);
        if (defMaxAmount == type(uint256).max && defSlope == 0) {
            RateLimitsLike(pau).setUnlimitedRateLimitData(key);
            emit SetRateLimit(pau, key, type(uint256).max, 0);
        } else {
            RateLimitsLike.RateLimitData memory current = RateLimitsLike(pau).getRateLimitData(key);
            bool safe = maxAmount <= defMaxAmount && slope <= defSlope || maxAmount <= current.maxAmount && slope <= current.slope;
            require(safe || block.timestamp >= zzz[pau][key] + hop, "Configurator/increment-too-soon");
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

    function callControllerAction(address pau, bytes calldata data) external govOps(pau) returns (bytes memory ret) {
        require(atwlState.isControllerActionEnabled(keccak256(data), pau), "Configurator/not-valid-data");
        bool ok;
        (ok, ret) = pau.call(data);
        require(ok, "Configurator/call-failed");
    }
}
