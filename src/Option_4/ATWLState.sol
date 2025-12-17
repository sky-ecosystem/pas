// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

contract ATWLState {

    // --- Storage variables ---

    mapping(address usr => uint256 allowed)                                 public wards;
    mapping(address pau => mapping(address usr => uint256 allowed))         public govOps;
    mapping(bytes32 key => mapping(address pau => DefaultRateLimits limit)) public initRateLimits;        // pau == address(0) every pau allowed
    mapping(bytes32 key => mapping(address pau => bool allowed))            public initControllerActions; // pau == address(0) every pau allowed

    struct DefaultRateLimits {
        uint256 maxAmount;
        uint256 slope;
    }

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event AddGovOps(address indexed pau, address indexed usr);
    event DelGovOps(address indexed pau, address indexed usr);
    event AddInitRateLimits(bytes32 indexed key, address indexed pau, uint256 maxAmount, uint256 slope);
    event DelInitRateLimits(bytes32 indexed key, address indexed pau);
    event AddInitControllerActions(bytes32 indexed key, address indexed pau);
    event DelInitControllerActions(bytes32 indexed key, address indexed pau);

    // --- Modifiers ---

    modifier auth() {
        require(wards[msg.sender] == 1, "Configurator/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- External getters ---

    function getInitRateLimits(bytes32 key, address pau) external view returns (DefaultRateLimits memory defaultRateLimits) {
        defaultRateLimits = initRateLimits[key][pau];
        if (defaultRateLimits.maxAmount == 0 || defaultRateLimits.slope == 0) {
            // If not set for specific pau, check in general
            defaultRateLimits = initRateLimits[key][address(0)];
        }
    }

    function isControllerActionEnabled(bytes32 key, address pau) external view returns (bool ok) {
        ok = initControllerActions[key][address(0)] || // address(0) enabled for every pau
             initControllerActions[key][pau];
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

    // TODO: for now roles system is outsourced to an external contract for the following functions:

    function addGovOps(address pau, address usr) external auth {
        govOps[pau][usr] = 1;
        emit AddGovOps(pau, usr);
    }

    function delGovOps(address pau, address usr) external auth {
        govOps[pau][usr] = 0;
        emit DelGovOps(pau, usr);
    }

    function addInitRateLimits(bytes32 key, address pau, uint256 maxAmount, uint256 slope) external auth {
        initRateLimits[key][pau] = DefaultRateLimits(maxAmount, slope);
        emit AddInitRateLimits(key, pau, maxAmount, slope);
    }

    function delInitRateLimits(bytes32 key, address pau) external auth {
        delete initRateLimits[key][pau];
        emit DelInitRateLimits(key, pau);
    }

    function addInitControllerActions(bytes calldata data, address pau) external auth returns (bytes32 key) {
        key = keccak256(data);
        initControllerActions[key][pau] = true;
        emit AddInitControllerActions(key, pau);
    }

    function addInitControllerActions(bytes32 key, address pau) external auth {
        // TODO: We will have to remove this function if finally having to save or log the raw data for enumeration purposes
        initControllerActions[key][pau] = true;
        emit AddInitControllerActions(key, pau);
    }

    function delInitControllerActions(bytes32 key, address pau) external auth {
        delete initControllerActions[key][pau];
        emit DelInitControllerActions(key, pau);
    }

}
