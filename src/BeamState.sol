// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

contract BeamState {

    // --- Storage variables ---

    mapping(address usr => uint256 allowed)                                 public wards;
    mapping(address usr => bytes32 rolesData)                               public userRoles;
    mapping(bytes4  sig => bytes32 rolesData)                               public actionsRoles;
    mapping(address cBeam => uint256 added)                                 public cBeams;                // allowed == 0 => false, allowed == 1 => true
    mapping(address pau => mapping(address cBeam => uint256 allowed))       public pauCBeams;             // allowed == 0 => false, allowed == 1 => true
    mapping(bytes32 key => mapping(address pau => DefaultRateLimits limit)) public initRateLimits;        // pau == address(0) every pau allowed
    mapping(bytes32 key => mapping(address pau => bool allowed))            public initControllerActions; // pau == address(0) every pau allowed
    mapping(address pau => uint256 value)                                   public hop;                   // pau == address(0) => general backup configuration
    mapping(address pau => uint256 value)                                   public maxChange;             // pau == address(0) => general backup configuration

    struct DefaultRateLimits {
        uint256 maxAmount;
        uint256 slope;
    }

    // --- Constants ---

    uint256 internal constant WAD = 10**18;

    // --- Events ---

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event SetUserRole(address indexed who, uint8 indexed role, bool enabled);
    event SetRoleAction(uint8 indexed role, bytes4 sig, bool enabled);
    event SetHop(address indexed pau, uint256 value);
    event SetMaxChange(address indexed pau, uint256 value);
    event AddCBeam(address indexed cBeam);
    event DelCBeam(address indexed cBeam);
    event SetCBeamForPau(address indexed pau, address indexed cBeam);
    event UnsetCBeamForPau(address indexed pau, address indexed cBeam);
    event AddInitRateLimits(bytes32 indexed key, address indexed pau, uint256 maxAmount, uint256 slope);
    event DelInitRateLimits(bytes32 indexed key, address indexed pau);
    event AddInitControllerActions(bytes32 indexed key, address indexed pau);
    event DelInitControllerActions(bytes32 indexed key, address indexed pau);

    // --- Modifiers ---

    modifier auth() {
        require(wards[msg.sender] == 1, "BeamState/not-authorized");
        _;
    }

    modifier roleAuth() {
        require(
            userRoles[msg.sender] & actionsRoles[msg.sig] != bytes32(0) ||
            wards[msg.sender] == 1, "BeamState/role-not-authorized"
        );
        _;
    }

    // --- Constructor ---

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- External getters ---

    function hasUserRole(address usr, uint8 role) external view returns (bool has) {
        has = userRoles[usr] & bytes32(uint256(1) << role) != bytes32(0);
    }

    function isActionInRole(bytes4 sig, uint8 role) external view returns (bool has) {
        has = actionsRoles[sig] & bytes32(uint256(1) << role) != bytes32(0);
    }

    function getHop(address pau) external view returns (uint256 hop_) {
        hop_ = hop[pau]; hop_ = hop_ != 0 ? hop_ : hop[address(0)];
    }

    function getMaxChange(address pau) external view returns (uint256 maxChange_) {
        maxChange_ = maxChange[pau]; maxChange_ = maxChange_ != 0 ? maxChange_ : maxChange[address(0)];
    }

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

    function setUserRole(address who, uint8 role, bool enabled) public auth {
        bytes32 mask = bytes32(uint256(1) << role);
        if (enabled) {
            userRoles[who] |= mask;
        } else {
            userRoles[who] &= ~mask;
        }
        emit SetUserRole(who, role, enabled);
    }

    function setRoleAction(uint8 role, bytes4 sig, bool enabled) external auth {
        bytes32 mask = bytes32(uint256(1) << role);
        if (enabled) {
            actionsRoles[sig] |= mask;
        } else {
            actionsRoles[sig] &= ~mask;
        }
        emit SetRoleAction(role, sig, enabled);
    }

    // --- Role authed functions ---

    function setHop(address pau, uint256 value) external roleAuth {
        hop[pau] = value;
        emit SetHop(pau, value);
    }

    function setMaxChange(address pau, uint256 value) external roleAuth {
        require(value >= WAD, "Configurator/maxChange-below-1x");
        maxChange[pau] = value;
        emit SetMaxChange(pau, value);
    }

    function addCBeam(address cBeam) external roleAuth {
        cBeams[cBeam] = 1;
        emit AddCBeam(cBeam);
    }

    function delCBeam(address cBeam) external roleAuth {
        cBeams[cBeam] = 0;
        emit DelCBeam(cBeam);
    }

    function setCBeamForPau(address pau, address cBeam) external roleAuth {
        require(cBeams[cBeam] == 1, "BeamState/not-existing-cBeam");
        pauCBeams[pau][cBeam] = 1;
        emit SetCBeamForPau(pau, cBeam);
    }

    function unsetCBeamForPau(address pau, address cBeam) external roleAuth {
        pauCBeams[pau][cBeam] = 0;
        emit UnsetCBeamForPau(pau, cBeam);
    }

    function addInitRateLimits(bytes32 key, address pau, uint256 maxAmount, uint256 slope) external roleAuth {
        initRateLimits[key][pau] = DefaultRateLimits(maxAmount, slope);
        emit AddInitRateLimits(key, pau, maxAmount, slope);
    }

    function delInitRateLimits(bytes32 key, address pau) external roleAuth {
        delete initRateLimits[key][pau];
        emit DelInitRateLimits(key, pau);
    }

    function addInitControllerActions(bytes calldata data, address pau) external roleAuth returns (bytes32 key) {
        key = keccak256(data);
        initControllerActions[key][pau] = true;
        emit AddInitControllerActions(key, pau);
    }

    function delInitControllerActions(bytes32 key, address pau) external roleAuth {
        delete initControllerActions[key][pau];
        emit DelInitControllerActions(key, pau);
    }
}
