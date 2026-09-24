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
import { PASFactory, PASFactoryConfig } from "src/PASFactory.sol";
import { BeamState } from "src/BeamState.sol";
import { Configurator } from "src/Configurator.sol";
import { Timelock } from "src/timelock/Timelock.sol";

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
        factory = new PASFactory();

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

    function _assertInit(PASInstance memory pas) internal view {
        BeamState beamState = BeamState(pas.beamState);
        Configurator configurator = Configurator(pas.configurator);
        Timelock timelock = Timelock(payable(pas.timelock));

        assertEq(address(configurator.beamState()), pas.beamState, "configurator should reference the deployed BeamState");
        assertEq(timelock.getMinDelay(), cfg.minDelay, "timelock minDelay should equal configured minDelay");

        assertTrue(beamState.hasUserRole(address(timelock), DELAYED), "timelock should hold BeamState DELAYED role");
        assertTrue(beamState.hasUserRole(cfg.coreCouncil, IMMEDIATE), "coreCouncil should hold BeamState IMMEDIATE role");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), cfg.coreCouncil), "coreCouncil should hold Timelock PROPOSER_ROLE");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), cfg.coreCouncil), "coreCouncil should hold Timelock CANCELLER_ROLE");
        for (uint256 i; i < cfg.cancellers.length; i++) {
            assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), cfg.cancellers[i]), "configured canceller should hold Timelock CANCELLER_ROLE");
        }
        for (uint256 i; i < cfg.pausers.length; i++) {
            assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), cfg.pausers[i]), "configured pauser should hold Timelock PAUSER_ROLE");
        }
    }

    function _assertOwnershipHandedOver(PASInstance memory pas) internal view {
        BeamState beamState = BeamState(pas.beamState);
        Timelock timelock = Timelock(payable(pas.timelock));
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        assertEq(beamState.wards(admin), 1, "admin should be a BeamState ward");
        assertEq(beamState.wards(address(factory)), 0, "factory should no longer be a BeamState ward");
        assertEq(beamState.wards(address(factory.deployer())), 0, "deployer should no longer be a BeamState ward");
        assertTrue(timelock.hasRole(adminRole, admin), "admin should hold Timelock DEFAULT_ADMIN_ROLE");
        assertFalse(timelock.hasRole(adminRole, address(factory)), "factory should no longer hold Timelock DEFAULT_ADMIN_ROLE");
        assertFalse(timelock.hasRole(timelock.PAUSER_ROLE(), address(factory)), "factory should no longer hold Timelock PAUSER_ROLE");
    }

    // --- Tests ---

    function testDeployFull() public {
        _fullConfig();
        PASInstance memory pas = factory.deploy(cfg);

        BeamState beamState = BeamState(pas.beamState);
        Timelock timelock = Timelock(payable(pas.timelock));

        // PASInit.init
        _assertInit(pas);

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
        PASInstance memory pas = factory.deploy(cfg);

        BeamState beamState = BeamState(pas.beamState);
        Timelock timelock = Timelock(payable(pas.timelock));

        // PASInit.init
        _assertInit(pas);

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

    function testDeployEmitsEvent() public {
        address deployer = address(factory.deployer());
        uint64 nonce = vm.getNonce(deployer);
        address beamState = vm.computeCreateAddress(deployer, nonce);
        address configurator = vm.computeCreateAddress(deployer, nonce + 1);
        address timelock = vm.computeCreateAddress(deployer, nonce + 2);

        vm.expectEmit(address(factory));
        emit PASFactory.Deployment(admin, beamState, configurator, timelock);
        PASInstance memory pas = factory.deploy(cfg);

        assertEq(pas.beamState, beamState, "returned beamState should match precomputed address");
        assertEq(pas.configurator, configurator, "returned configurator should match precomputed address");
        assertEq(pas.timelock, timelock, "returned timelock should match precomputed address");
    }

    function testDeployRevertsOnZeroAdmin() public {
        cfg.admin = address(0);
        vm.expectRevert("PASFactory/admin-zero-address");
        factory.deploy(cfg);
    }

    function testDeployRevertsOnFactoryAsAdmin() public {
        cfg.admin = address(factory);
        vm.expectRevert("PASFactory/admin-is-factory");
        factory.deploy(cfg);
    }

    function testDeployRevertsOnZeroHop() public {
        cfg.hop = 0;
        vm.expectRevert("PASFactory/hop-zero");
        factory.deploy(cfg);
    }

    function testDeployCost() public {
        _fullConfig();

        uint256 startGas = gasleft();
        factory.deploy(cfg);
        uint256 endGas = gasleft();
        uint256 totalGas = startGas - endGas;

        // Fail if deploy is too expensive (higher than EIP-7825 tx gas limit cap: 2^24)
        assertLe(totalGas, 2 ** 24, "deploy() cost too high");
    }
}
