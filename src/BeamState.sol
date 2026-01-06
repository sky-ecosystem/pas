// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

contract BeamState {

    // --- Storage variables ---

    mapping(address usr => uint256 allowed)                                   public wards;
    mapping(address cBeam => uint256 added)                                   public cBeams;                // allowed == 0 => false, allowed == 1 => true
    mapping(address rBeam => mapping(address cBeam => uint256 allowed))       public cBeamsForRBeams;       // allowed == 0 => false, allowed == 1 => true
    mapping(bytes32 key => mapping(address rBeam => DefaultRateLimits limit)) public initRateLimits;        // rBeam == address(0) every rBeam allowed
    mapping(bytes32 key => mapping(address rBeam => bool allowed))            public initControllerActions; // rBeam == address(0) every rBeam allowed

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

    function getInitRateLimits(bytes32 key, address rBeam) external view returns (DefaultRateLimits memory defaultRateLimits) {
        defaultRateLimits = initRateLimits[key][rBeam];
        if (defaultRateLimits.maxAmount == 0 || defaultRateLimits.slope == 0) {
            // If not set for specific rBeam, check in general
            defaultRateLimits = initRateLimits[key][address(0)];
        }
    }

    function isControllerActionEnabled(bytes32 key, address rBeam) external view returns (bool ok) {
        ok = initControllerActions[key][address(0)] || // address(0) enabled for every rBeam
             initControllerActions[key][rBeam];
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

    function addInitRateLimits(bytes32 key, address rBeam, uint256 maxAmount, uint256 slope) external auth {
        initRateLimits[key][rBeam] = DefaultRateLimits(maxAmount, slope);
        emit AddInitRateLimits(key, rBeam, maxAmount, slope);
    }

    function delInitRateLimits(bytes32 key, address rBeam) external auth {
        delete initRateLimits[key][rBeam];
        emit DelInitRateLimits(key, rBeam);
    }

    function addInitControllerActions(bytes calldata data, address rBeam) external auth returns (bytes32 key) {
        key = keccak256(data);
        initControllerActions[key][rBeam] = true;
        emit AddInitControllerActions(key, rBeam);
    }

    function addInitControllerActions(bytes32 key, address rBeam) external auth {
        // TODO: We will have to remove this function if finally having to save or log the raw data for enumeration purposes
        initControllerActions[key][rBeam] = true;
        emit AddInitControllerActions(key, rBeam);
    }

    function delInitControllerActions(bytes32 key, address rBeam) external auth {
        delete initControllerActions[key][rBeam];
        emit DelInitControllerActions(key, rBeam);
    }

}
