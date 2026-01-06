// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

contract BeamState {

    // --- Storage variables ---

    mapping(address usr => uint256 allowed)                                 public wards;
    mapping(address cBeam => uint256 added)                                 public cBeams;                // allowed == 0 => false, allowed == 1 => 
    mapping(address rBeam => mapping(address cBeam => uint256 allowed))     public cBeamsForRBeams;       // allowed == 0 => false, allowed == 1 => true
    mapping(bytes32 key => mapping(address pau => DefaultRateLimits limit)) public initRateLimits;        // pau == address(0) every pau allowed
    mapping(bytes32 key => mapping(address pau => bool allowed))            public initControllerActions; // pau == address(0) every pau allowed

    struct DefaultRateLimits {
        uint256 maxAmount;
        uint256 slope;
    }

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event AddCBeam(address indexed cBeam);
    event DelCBeam(address indexed cBeam);
    event AddCBeamForRBeam(address indexed rBeam, address indexed cBeam);
    event DelCBeamForRBeam(address indexed rBeam, address indexed cBeam);
    event AddInitRateLimits(bytes32 indexed key, address indexed rBeam, uint256 maxAmount, uint256 slope);
    event DelInitRateLimits(bytes32 indexed key, address indexed rBeam);
    event AddInitControllerActions(bytes32 indexed key, address indexed rBeam);
    event DelInitControllerActions(bytes32 indexed key, address indexed rBeam);

    // --- Modifiers ---

    modifier auth() {
        require(wards[msg.sender] == 1, "BeamState/not-authorized");
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

    function addCBeam(address cBeam) external auth {
        cBeams[cBeam] = 1;
        emit AddCBeam(cBeam);
    }

    function delCBeam(address cBeam) external auth {
        cBeams[cBeam] = 0;
        emit DelCBeam(cBeam);
    }

    function addCBeamForRBeam(address rBeam, address cBeam) external auth {
        require(cBeams[cBeam] == 1, "BeamState/not-existing-cBeam");
        cBeamsForRBeams[rBeam][cBeam] = 1;
        emit AddCBeamForRBeam(rBeam, cBeam);
    }

    function delCBeamForRBeam(address rBeam, address cBeam) external auth {
        cBeamsForRBeams[rBeam][cBeam] = 0;
        emit DelCBeamForRBeam(rBeam, cBeam);
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
