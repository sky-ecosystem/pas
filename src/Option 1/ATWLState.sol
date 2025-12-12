// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

contract ATWLState {

    // --- Storage variables ---

    mapping(address usr => uint256 allowed) public wards;
    mapping(address usr => uint256 allowed) public bud;
    mapping(bytes32 key => DefaultRateLimits) public defaults;
    mapping(bytes32 prime => address) public rateLimits;

    struct DefaultRateLimits {
        uint256 maxAmount;
        uint256 slope;
    }

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event AddDefault(bytes32 indexed key, uint256 maxAmount, uint256 slope);
    event DelDefault(bytes32 indexed key);
    event AddPrime(bytes32 indexed prime, address rateLimits_);
    event DelPrime(bytes32 indexed prime);

    // --- Modifiers ---

    modifier auth() {
        require(wards[msg.sender] == 1, "Configurator/not-authorized");
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

    function kiss(address usr) external auth {
        bud[usr] = 1;
        emit Kiss(usr);
    }

    function diss(address usr) external auth {
        bud[usr] = 0;
        emit Diss(usr);
    }

    // Tolled functions

    function addDefault(
        bytes32 key,
        uint256 maxAmount,
        uint256 slope
    ) external toll {
        defaults[key] = DefaultRateLimits(maxAmount, slope);

        emit AddDefault(key, maxAmount, slope);
    }

    function delDefault(bytes32 key) external toll {
        delete defaults[key];

        emit DelDefault(key);
    }

    function addPrime(
        bytes32 prime,
        address rateLimits_
    ) external toll {
        rateLimits[prime] = rateLimits_;

        emit AddPrime(prime, rateLimits_);
    }

    function delPrime(
        bytes32 prime
    ) external toll {
        rateLimits[prime] = address(0);

        emit DelPrime(prime);
    }
}
