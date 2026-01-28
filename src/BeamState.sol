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

contract BeamState {

    // --- Storage variables ---

    // Note: Some of the variables defined here are for controlling the actions of the Configurator.
    // That's why they might not have a direct apparent reason within this contract itself.

    mapping(address usr => uint256 allowed)                                         public wards;
    mapping(address usr => bytes32 rolesData)                                       public userRoles;
    mapping(bytes4  sig => bytes32 rolesData)                                       public actionsRoles;
    mapping(address rateLimits_ => uint256 added)                                   public rateLimits;            // allowed == 0 => false, allowed == 1 => true
    mapping(address controller => uint256 added)                                    public controllers;           // allowed == 0 => false, allowed == 1 => true
    mapping(address cBeam => uint256 added)                                         public cBeams;                // allowed == 0 => false, allowed == 1 => true
    mapping(address rateLimits_ => mapping(address cBeam => uint256 allowed))       public rateLimitsCBeams;      // allowed == 0 => false, allowed == 1 => true
    mapping(address controller => mapping(address cBeam => uint256 allowed))        public controllersCBeams;     // allowed == 0 => false, allowed == 1 => true
    mapping(bytes32 key => mapping(address rateLimits_ => DefaultRateLimits limit)) public initRateLimits;        // rateLimits == address(0) every rateLimits allowed
    mapping(bytes32 key => mapping(address controller => bool allowed))             public initControllerActions; // controller == address(0) every controller allowed
    mapping(address rateLimits_ => uint256 value)                                   public hop;                   // rateLimits == address(0) => general backup configuration
    mapping(address rateLimits_ => uint256 value)                                   public maxChange;             // rateLimits == address(0) => general backup configuration

    bool public stopped;

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
    event Stop();
    event Start();
    event SetHop(address indexed rateLimits_, uint256 value);
    event SetMaxChange(address indexed rateLimits_, uint256 value);
    event AddCBeam(address indexed cBeam);
    event DelCBeam(address indexed cBeam);
    event AddRateLimits(address indexed rateLimits_);
    event DelRateLimits(address indexed rateLimits_);
    event AddController(address indexed controller);
    event DelController(address indexed controller);
    event SetCBeamForController(address indexed controller, address indexed cBeam);
    event UnsetCBeamForController(address indexed controller, address indexed cBeam);
    event SetCBeamForRateLimits(address indexed rateLimits_, address indexed cBeam);
    event UnsetCBeamForRateLimits(address indexed rateLimits_, address indexed cBeam);
    event AddInitRateLimits(bytes32 indexed key, address indexed rateLimits_, uint256 maxAmount, uint256 slope);
    event DelInitRateLimits(bytes32 indexed key, address indexed rateLimits_);
    event AddInitControllerActions(bytes32 indexed key, address indexed controller);
    event DelInitControllerActions(bytes32 indexed key, address indexed controller);

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

    function getHop(address rateLimits_) external view returns (uint256 hop_) {
        hop_ = hop[rateLimits_]; hop_ = hop_ != 0 ? hop_ : hop[address(0)];
    }

    function getMaxChange(address rateLimits_) external view returns (uint256 maxChange_) {
        maxChange_ = maxChange[rateLimits_]; maxChange_ = maxChange_ != 0 ? maxChange_ : maxChange[address(0)];
    }

    function getInitRateLimits(bytes32 key, address rateLimits_) external view returns (DefaultRateLimits memory defaultRateLimits) {
        defaultRateLimits = initRateLimits[key][rateLimits_];
        if (defaultRateLimits.maxAmount == 0 && defaultRateLimits.slope == 0) {
            // If not set for specific rateLimits, check in general
            defaultRateLimits = initRateLimits[key][address(0)];
        }
    }

    function isControllerActionEnabled(bytes32 key, address controller) external view returns (bool ok) {
        ok = initControllerActions[key][address(0)] || // address(0) enabled for every controller
             initControllerActions[key][controller];
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

    function setUserRole(address who, uint8 role, bool enabled) external auth {
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

    function stop() external roleAuth {
        stopped = true;
        emit Stop();
    }

    function start() external roleAuth {
        stopped = false;
        emit Start();
    }

    function setHop(address rateLimits_, uint256 value) external roleAuth {
        hop[rateLimits_] = value;
        emit SetHop(rateLimits_, value);
    }

    function setMaxChange(address rateLimits_, uint256 value) external roleAuth {
        require(value >= WAD, "BeamState/maxChange-below-1x");
        maxChange[rateLimits_] = value;
        emit SetMaxChange(rateLimits_, value);
    }

    function addRateLimits(address rateLimits_) external roleAuth {
        rateLimits[rateLimits_] = 1;
        emit AddRateLimits(rateLimits_);
    }

    function delRateLimits(address rateLimits_) external roleAuth {
        // Note: it's a soft deprecation avoiding pairing it with new cBeams.
        // Existing relationships need to be individually unset for full removal.
        rateLimits[rateLimits_] = 0;
        emit DelRateLimits(rateLimits_);
    }

    function addController(address controller) external roleAuth {
        controllers[controller] = 1;
        emit AddController(controller);
    }

    function delController(address controller) external roleAuth {
        // Note: it's a soft deprecation avoiding pairing it with new cBeams.
        // Existing relationships need to be individually unset for full removal.
        controllers[controller] = 0;
        emit DelController(controller);
    }

    function addCBeam(address cBeam) external roleAuth {
        cBeams[cBeam] = 1;
        emit AddCBeam(cBeam);
    }

    function delCBeam(address cBeam) external roleAuth {
        // Note: it's a soft deprecation avoiding pairing it with new rateLimits and controllers.
        // Existing relationships need to be individually unset for full removal.
        cBeams[cBeam] = 0;
        emit DelCBeam(cBeam);
    }

    // Note: Once cBEAMS are whitelisted they can be assigned to controllers/rate-limits (potentially without delay),
    // so theoretically they can be positioned to interfere with each other. This is known and assumed to be monitored

    function setCBeamForRateLimits(address rateLimits_, address cBeam) external roleAuth {
        require(rateLimits[rateLimits_] == 1, "BeamState/not-existing-rateLimits");
        require(cBeams[cBeam] == 1, "BeamState/not-existing-cBeam");
        rateLimitsCBeams[rateLimits_][cBeam] = 1;
        emit SetCBeamForRateLimits(rateLimits_, cBeam);
    }

    function unsetCBeamForRateLimits(address rateLimits_, address cBeam) external roleAuth {
        rateLimitsCBeams[rateLimits_][cBeam] = 0;
        emit UnsetCBeamForRateLimits(rateLimits_, cBeam);
    }

    function setCBeamForController(address controller, address cBeam) external roleAuth {
        require(controllers[controller] == 1, "BeamState/not-existing-controller");
        require(cBeams[cBeam] == 1, "BeamState/not-existing-cBeam");
        controllersCBeams[controller][cBeam] = 1;
        emit SetCBeamForController(controller, cBeam);
    }

    function unsetCBeamForController(address controller, address cBeam) external roleAuth {
        controllersCBeams[controller][cBeam] = 0;
        emit UnsetCBeamForController(controller, cBeam);
    }

    function addInitRateLimits(bytes32 key, address rateLimits_, uint256 maxAmount, uint256 slope) external roleAuth {
        initRateLimits[key][rateLimits_] = DefaultRateLimits(maxAmount, slope);
        emit AddInitRateLimits(key, rateLimits_, maxAmount, slope);
    }

    function delInitRateLimits(bytes32 key, address rateLimits_) external roleAuth {
        delete initRateLimits[key][rateLimits_];
        emit DelInitRateLimits(key, rateLimits_);
    }

    function addInitControllerActions(bytes calldata data, address controller) external roleAuth returns (bytes32 key) {
        key = keccak256(data);
        initControllerActions[key][controller] = true;
        emit AddInitControllerActions(key, controller);
    }

    function delInitControllerActions(bytes32 key, address controller) external roleAuth {
        delete initControllerActions[key][controller];
        emit DelInitControllerActions(key, controller);
    }
}
