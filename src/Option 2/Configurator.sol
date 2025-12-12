// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

interface RateLimitsLike {
    struct RateLimitData {
        uint256 maxAmount;
        uint256 slope;
        uint256 lastAmount;
        uint256 lastUpdated;
    }

    function getRateLimitData(bytes32 key) external view returns (RateLimitData memory);
    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;
}

contract Configurator {

    // --- Storage variables ---

    mapping(address usr => uint256 allowed) public wards;
    mapping(address usr => uint256 allowed) public can;
    mapping(address usr => uint256 allowed) public bud;
    mapping(bytes32 key => DefaultRateLimits) public defaults;
    mapping(bytes32 prime => RateLimitsLike) public rateLimits;
    mapping(bytes32 prime => mapping(bytes32 key => uint256 timestamp)) public zzz;
    uint256 public hop;
    uint256 public maxChange;

    struct DefaultRateLimits {
        uint256 maxAmount;
        uint256 slope;
    }

    // --- Constants ---

    uint256 internal constant WAD = 10**18;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Hope(address indexed usr);
    event Nope(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event AddDefault(bytes32 indexed key, uint256 maxAmount, uint256 slope);
    event DelDefault(bytes32 indexed key);
    event AddPrime(bytes32 indexed prime, address rateLimits_);
    event DelPrime(bytes32 indexed prime);
    event SetRateLimit(bytes32 indexed prime, bytes32 indexed key, uint256 maxAmount, uint256 slope, bool isIcrement, uint256 timestamp);

    // --- Modifiers ---

    modifier auth() {
        require(wards[msg.sender] == 1, "Configurator/not-authorized");
        _;
    }

    modifier time() {
        require(can[msg.sender] == 1, "Configurator/not-can");
        _;
    }

    modifier toll() {
        require(bud[msg.sender] == 1, "Configurator/not-bud");
        _;
    }

    // --- Constructor ---

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
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

    function hope(address usr) external auth {
        can[usr] = 1;
        emit Hope(usr);
    }

    function nope(address usr) external auth {
        can[usr] = 0;
        emit Nope(usr);
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

    // Timelocked functions

    function addDefault(bytes32 key, uint256 maxAmount, uint256 slope) external time {
        defaults[key] = DefaultRateLimits(maxAmount, slope);

        emit AddDefault(key, maxAmount, slope);
    }

    function delDefault(bytes32 key) external time {
        delete defaults[key];

        emit DelDefault(key);
    }

    function addPrime(bytes32 prime, address rateLimits_) external time {
        rateLimits[prime] = RateLimitsLike(rateLimits_);

        emit AddPrime(prime, rateLimits_);
    }

    function delPrime(bytes32 prime) external time {
        rateLimits[prime] = RateLimitsLike(address(0));

        emit DelPrime(prime);
    }

    // Tolled functions

    function initRateLimit(bytes32 prime, bytes32 key) external toll {
        DefaultRateLimits memory d = defaults[key];
        require(d.maxAmount > 0 && d.slope > 0, "Configurator/wrong-defaults");
        RateLimitsLike.RateLimitData memory current = rateLimits[prime].getRateLimitData(key);
        require(current.maxAmount == 0 || current.slope == 0, "Configurator/already-init");

        rateLimits[prime].setRateLimitData(key, d.maxAmount, d.slope);

        zzz[prime][key] = block.timestamp;

        emit SetRateLimit(prime, key, d.maxAmount, d.slope, true, block.timestamp);
    }

    function setRateLimit(bytes32 prime, bytes32 key, uint256 maxAmount, uint256 slope) external toll {
        RateLimitsLike.RateLimitData memory current = rateLimits[prime].getRateLimitData(key);
        bool isIncrement = maxAmount > current.maxAmount || slope > current.slope;
        require(current.maxAmount > 0 && current.slope > 0, "Configurator/needs-init");
        require(!isIncrement || block.timestamp >= zzz[prime][key] + hop, "Configurator/increment-too-soon");
        require(maxAmount <= current.maxAmount * maxChange / WAD, "Configurator/maxChange-maxAmount"); // maxChange always >= WAD
        require(slope <= current.slope * maxChange / WAD, "Configurator/maxChange-slope");

        if (isIncrement) {
            zzz[prime][key] = block.timestamp;
        }

        rateLimits[prime].setRateLimitData(key, maxAmount, slope);

        emit SetRateLimit(prime, key, maxAmount, slope, isIncrement, block.timestamp);
    }
}
