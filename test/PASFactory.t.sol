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
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.24;

import "dss-test/DssTest.sol";
import { PASInstance } from "deploy/PASInstance.sol";
import { InitRateLimitConfig, InitControllerActionConfig, InitCBeamConfig } from "deploy/PASInit.sol";
import { PASFactory, PASFactoryConfig } from "deploy/PASFactory.sol";
import { BeamState } from "src/BeamState.sol";
import { Configurator } from "src/Configurator.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

contract PASFactoryTest is DssTest {

    PASFactory factory;

    address admin = address(0xA);
    address coreCouncil = address(0xB);
    address canceller = address(0xC);
    address pauser = address(0xD);
    address cBeam = address(0xE);
    address rateLimits = address(0xF1);
    address controller = address(0xF2);

    uint256 constant MIN_DELAY = 1 days;
    uint256 constant HOP = 1 hours;
    uint256 constant MAX_CHANGE = 1.1e18;
    bytes32 constant KEY = keccak256("some-key");
    bytes constant ACTION = hex"deadbeef";

    uint8 constant DELAYED = 1;
    uint8 constant IMMEDIATE = 2;

    PASFactoryConfig cfg;

    function setUp() public {
        cfg.admin = admin;
        cfg.minDelay = MIN_DELAY;
        cfg.coreCouncil = coreCouncil;
        cfg.hop = HOP;
    }

    // --- Helpers ---

    function _fullConfig() internal {
        cfg.cancellers.push(canceller);
        cfg.pausers.push(pauser);

        cfg.maxChange = MAX_CHANGE;
        cfg.rateLimits.push(rateLimits);
        cfg.controllers.push(controller);
        cfg.cBeamConfigs.push(InitCBeamConfig({
            cBeam: cBeam,
            rateLimits: cfg.rateLimits,
            controllers: cfg.controllers
        }));

        cfg.rateLimitConfigs.push(InitRateLimitConfig({
            key: KEY,
            rateLimits: rateLimits,
            maxAmount: 1_000_000e18,
            slope: 1e18
        }));
        cfg.controllerActionConfigs.push(InitControllerActionConfig({
            data: ACTION,
            controller: controller
        }));

        cfg.timelockPaused = true;
    }

    function _deploy() internal returns (PASInstance memory pas, Vm.Log[] memory logs) {
        vm.recordLogs();
        factory = new PASFactory(cfg);
        logs = vm.getRecordedLogs();

        // Instance addresses are only exposed through the `Deployment` event
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == PASFactory.Deployment.selector) {
                assertFalse(found, "Deployment should be emitted once");
                assertEq(address(uint160(uint256(logs[i].topics[1]))), cfg.admin, "Deployment admin should equal configured admin");
                (pas.beamState, pas.configurator, pas.timelock) = abi.decode(logs[i].data, (address, address, address));
                found = true;
            }
        }
        assertTrue(found, "Deployment should be emitted");

        // Emitted addresses should be the ones created by the factory, derived from its nonces
        assertEq(pas.beamState,    vm.computeCreateAddress(address(factory), 1), "Deployment beamState should be the factory's 1st CREATE");
        assertEq(pas.configurator, vm.computeCreateAddress(address(factory), 2), "Deployment configurator should be the factory's 2nd CREATE");
        assertEq(pas.timelock,     vm.computeCreateAddress(address(factory), 3), "Deployment timelock should be the factory's 3rd CREATE");
    }

    function _assertInit(PASInstance memory pas, Vm.Log[] memory logs) internal view {
        BeamState beamState = BeamState(pas.beamState);
        Configurator configurator = Configurator(pas.configurator);
        Timelock timelock = Timelock(payable(pas.timelock));

        assertEq(address(configurator.beamState()), pas.beamState, "configurator should reference the deployed BeamState");
        assertEq(timelock.getMinDelay(), cfg.minDelay, "timelock minDelay should equal configured minDelay");

        // BeamState roles: exact bitmasks, only 1 role per user/action is expected
        bytes32 delayed   = bytes32(uint256(1) << DELAYED);
        bytes32 immediate = bytes32(uint256(1) << IMMEDIATE);
        assertEq(beamState.userRoles(address(timelock)), delayed,   "timelock should hold exactly the DELAYED role");
        assertEq(beamState.userRoles(cfg.coreCouncil),   immediate, "coreCouncil should hold exactly the IMMEDIATE role");

        assertEq(beamState.actionsRoles(BeamState.start.selector),                    delayed, "start should be exactly DELAYED");
        assertEq(beamState.actionsRoles(BeamState.setHop.selector),                   delayed, "setHop should be exactly DELAYED");
        assertEq(beamState.actionsRoles(BeamState.setMaxChange.selector),             delayed, "setMaxChange should be exactly DELAYED");
        assertEq(beamState.actionsRoles(BeamState.addRateLimits.selector),            delayed, "addRateLimits should be exactly DELAYED");
        assertEq(beamState.actionsRoles(BeamState.addController.selector),            delayed, "addController should be exactly DELAYED");
        assertEq(beamState.actionsRoles(BeamState.addCBeam.selector),                 delayed, "addCBeam should be exactly DELAYED");
        assertEq(beamState.actionsRoles(BeamState.addInitRateLimits.selector),        delayed, "addInitRateLimits should be exactly DELAYED");
        assertEq(beamState.actionsRoles(BeamState.addInitControllerActions.selector), delayed, "addInitControllerActions should be exactly DELAYED");
        assertEq(beamState.actionsRoles(BeamState.stop.selector),                     immediate, "stop should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.delRateLimits.selector),            immediate, "delRateLimits should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.delController.selector),            immediate, "delController should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.delCBeam.selector),                 immediate, "delCBeam should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.setCBeamForRateLimits.selector),    immediate, "setCBeamForRateLimits should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.unsetCBeamForRateLimits.selector),  immediate, "unsetCBeamForRateLimits should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.setCBeamForController.selector),    immediate, "setCBeamForController should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.unsetCBeamForController.selector),  immediate, "unsetCBeamForController should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.delInitRateLimits.selector),        immediate, "delInitRateLimits should be exactly IMMEDIATE");
        assertEq(beamState.actionsRoles(BeamState.delInitControllerActions.selector), immediate, "delInitControllerActions should be exactly IMMEDIATE");

        // Timelock roles: expected holders
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "execution should be permissionless");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), cfg.coreCouncil), "coreCouncil should hold Timelock PROPOSER_ROLE");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), cfg.coreCouncil), "coreCouncil should hold Timelock CANCELLER_ROLE");
        for (uint256 i; i < cfg.cancellers.length; i++) {
            assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), cfg.cancellers[i]), "configured canceller should hold Timelock CANCELLER_ROLE");
        }
        for (uint256 i; i < cfg.pausers.length; i++) {
            assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), cfg.pausers[i]), "configured pauser should hold Timelock PAUSER_ROLE");
        }

        // Events: nothing have been granted or registered outside the configured set during deploy
        uint256 roleActions;
        uint256 initRateLimits;
        uint256 initControllerActions;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.emitter == pas.beamState && log.topics[0] == BeamState.SetRoleAction.selector) {
                roleActions++;
            } else if (log.emitter == pas.beamState && log.topics[0] == BeamState.AddInitRateLimits.selector) {
                initRateLimits++;
            } else if (log.emitter == pas.beamState && log.topics[0] == BeamState.AddInitControllerActions.selector) {
                initControllerActions++;
            } else if (log.emitter == pas.beamState && log.topics[0] == BeamState.SetUserRole.selector) {
                address who = address(uint160(uint256(log.topics[1])));
                assertTrue(who == address(timelock) || who == cfg.coreCouncil, "unexpected BeamState user role");
            } else if (log.emitter == pas.timelock && log.topics[0] == IAccessControl.RoleGranted.selector) {
                bytes32 role    = log.topics[1];
                address account = address(uint160(uint256(log.topics[2])));
                bool ok;
                if      (role == timelock.DEFAULT_ADMIN_ROLE()) ok = account == admin || account == address(timelock) || account == address(factory);
                else if (role == timelock.EXECUTOR_ROLE())      ok = account == address(0);
                else if (role == timelock.PROPOSER_ROLE())      ok = account == cfg.coreCouncil;
                else if (role == timelock.CANCELLER_ROLE())     ok = account == cfg.coreCouncil || _contains(cfg.cancellers, account);
                else if (role == timelock.PAUSER_ROLE())        ok =  (cfg.timelockPaused && account == address(factory)) || _contains(cfg.pausers, account);
                assertTrue(ok, "unexpected Timelock role grant");
            }
        }
        // Total number of BeamState action roles, init rate limits and init controller actions set
        assertEq(roleActions, 18, "unexpected number of BeamState action roles");
        assertEq(initRateLimits, cfg.rateLimitConfigs.length, "unexpected number of init rate limits");
        assertEq(initControllerActions, cfg.controllerActionConfigs.length, "unexpected number of init controller actions");
    }

    function _contains(address[] memory list, address item) internal pure returns (bool) {
        for (uint256 i; i < list.length; i++) {
            if (list[i] == item) return true;
        }
        return false;
    }

    function _assertOwnershipHandedOver(PASInstance memory pas) internal view {
        BeamState beamState = BeamState(pas.beamState);
        Timelock timelock = Timelock(payable(pas.timelock));
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        assertEq(beamState.wards(admin), 1, "admin should be a BeamState ward");
        assertEq(beamState.wards(address(factory)), 0, "factory should no longer be a BeamState ward");
        assertTrue(timelock.hasRole(adminRole, admin), "admin should hold Timelock DEFAULT_ADMIN_ROLE");
        assertFalse(timelock.hasRole(adminRole, address(factory)), "factory should no longer hold Timelock DEFAULT_ADMIN_ROLE");
        assertFalse(timelock.hasRole(timelock.PAUSER_ROLE(), address(factory)), "factory should no longer hold Timelock PAUSER_ROLE");
    }

    // --- Tests ---

    function testDeployFull() public {
        _fullConfig();
        (PASInstance memory pas, Vm.Log[] memory logs) = _deploy();

        BeamState beamState = BeamState(pas.beamState);
        Timelock timelock = Timelock(payable(pas.timelock));

        // PASInit.init
        _assertInit(pas, logs);

        // PASInit.initExtras
        assertEq(beamState.hop(address(0)), HOP, "global hop should equal configured hop");
        assertEq(beamState.maxChange(address(0)), MAX_CHANGE, "global maxChange should equal configured maxChange");
        assertEq(beamState.rateLimits(rateLimits), 1, "configured rateLimits should be registered in BeamState");
        assertEq(beamState.controllers(controller), 1, "configured controller should be registered in BeamState");
        assertEq(beamState.cBeams(cBeam), 1, "configured cBeam should be registered in BeamState");
        assertEq(beamState.rateLimitsCBeams(rateLimits, cBeam), 1, "cBeam should be authorized for configured rateLimits");
        assertEq(beamState.controllersCBeams(controller, cBeam), 1, "cBeam should be authorized for configured controller");

        // PASInit.initLimitsAndControllerData
        (uint256 maxAmount, uint256 slope) = beamState.initRateLimits(KEY, rateLimits);
        assertEq(maxAmount, 1_000_000e18, "init rate limit maxAmount should equal configured value");
        assertEq(slope, 1e18, "init rate limit slope should equal configured value");
        assertEq(beamState.initControllerActions(keccak256(ACTION), controller), 1, "configured controller action should be registered in BeamState");

        // PASInit.pauseTimelock
        assertTrue(timelock.paused(), "timelock should be paused");

        _assertOwnershipHandedOver(pas);
    }

    function testDeployMinimalSkipsOptionalSteps() public {
        (PASInstance memory pas, Vm.Log[] memory logs) = _deploy();

        BeamState beamState = BeamState(pas.beamState);
        Timelock timelock = Timelock(payable(pas.timelock));

        // PASInit.init
        _assertInit(pas, logs);

        // PASInit.initExtras ran with hop only
        assertEq(beamState.hop(address(0)), HOP, "global hop should equal configured hop");
        assertEq(beamState.maxChange(address(0)), 0, "global maxChange should be zero");
        assertEq(beamState.rateLimits(rateLimits), 0, "rateLimits should not be registered");
        assertEq(beamState.controllers(controller), 0, "controller should not be registered");
        assertEq(beamState.cBeams(cBeam), 0, "cBeam should not be registered");

        // PASInit.initLimitsAndControllerData skipped
        (uint256 maxAmount, uint256 slope) = beamState.initRateLimits(KEY, rateLimits);
        assertEq(maxAmount, 0, "init rate limit maxAmount should be zero");
        assertEq(slope, 0, "init rate limit slope should be zero");
        assertEq(beamState.initControllerActions(keccak256(ACTION), controller), 0, "controller action should not be registered");

        // PASInit.pauseTimelock skipped
        assertFalse(timelock.paused(), "timelock should not be paused");

        _assertOwnershipHandedOver(pas);
    }

    function testDeployWithOnlyRateLimitConfigs() public {
        cfg.rateLimitConfigs.push(InitRateLimitConfig({
            key: KEY,
            rateLimits: rateLimits,
            maxAmount: 1_000_000e18,
            slope: 1e18
        }));
        (PASInstance memory pas, Vm.Log[] memory logs) = _deploy();

        BeamState beamState = BeamState(pas.beamState);
        _assertInit(pas, logs);
        _assertOwnershipHandedOver(pas);

        (uint256 maxAmount, uint256 slope) = beamState.initRateLimits(KEY, rateLimits);
        assertEq(maxAmount, 1_000_000e18, "init rate limit maxAmount should equal configured value");
        assertEq(slope, 1e18, "init rate limit slope should equal configured value");
        assertEq(beamState.initControllerActions(keccak256(ACTION), controller), 0, "controller action should not be registered");
    }

    function testDeployWithOnlyControllerActionConfigs() public {
        cfg.controllerActionConfigs.push(InitControllerActionConfig({
            data: ACTION,
            controller: controller
        }));
        (PASInstance memory pas, Vm.Log[] memory logs) = _deploy();

        BeamState beamState = BeamState(pas.beamState);
        _assertInit(pas, logs);
        _assertOwnershipHandedOver(pas);

        assertEq(beamState.initControllerActions(keccak256(ACTION), controller), 1, "configured controller action should be registered in BeamState");
        (uint256 maxAmount, uint256 slope) = beamState.initRateLimits(KEY, rateLimits);
        assertEq(maxAmount, 0, "init rate limit maxAmount should be zero");
        assertEq(slope, 0, "init rate limit slope should be zero");
    }

    function testDeployRevertsOnZeroAdmin() public {
        cfg.admin = address(0);
        vm.expectRevert("PASFactory/admin-zero-address");
        new PASFactory(cfg);
    }

    function testDeployRevertsOnFactoryAsAdmin() public {
        cfg.admin = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert("PASFactory/admin-is-factory");
        new PASFactory(cfg);
    }

    function testDeployRevertsOnZeroHop() public {
        cfg.hop = 0;
        vm.expectRevert("PASFactory/hop-zero");
        new PASFactory(cfg);
    }

    function testDeployCost() public {
        _fullConfig();

        uint256 startGas = gasleft();
        new PASFactory(cfg);
        uint256 endGas = gasleft();
        uint256 totalGas = startGas - endGas;

        // Fail if deploy is too expensive (higher than EIP-7825 tx gas limit cap: 2^24)
        assertLe(totalGas, 2 ** 24, "PASFactory deployment cost too high");
    }

    function testInitcodeSize() public {
        _fullConfig();

        uint256 initcodeSize = abi.encodePacked(type(PASFactory).creationCode, abi.encode(cfg)).length;

        // Fail if initcode (creation code + constructor args) exceeds EIP-3860 limit: 2 * 24576
        assertLe(initcodeSize, 2 * 24576, "PASFactory initcode too large");
    }
}
