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

import "dss-test/DssTest.sol";
import { MCD, DssInstance } from "dss-test/MCD.sol";
import { PASInstance } from "deploy/PASInstance.sol";
import { PASDeploy } from "deploy/PASDeploy.sol";
import { PASInit, InitRateLimitConfig, InitControllerActionConfig, InitCBeamConfig } from "deploy/PASInit.sol";
import { BeamState } from "src/BeamState.sol";
import { Configurator, RateLimitsLike } from "src/Configurator.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { PASMom } from "src/PASMom.sol";

interface ChiefLike {
    function hat() external view returns (address);
}

// Interface for SparkController
interface ControllerLike {
    function rateLimits() external view returns (address);
    function setMintRecipient(uint32 domain, bytes32 mintRecipient) external;
    function mintRecipients(uint32 domain) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
}

// Extended RateLimitsLike with role management
interface RateLimitsWithRolesLike {
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
    function grantRole(bytes32 role, address account) external;
}

contract IntegrationTest is DssTest {

    // Mainnet addresses
    address constant SPARK_CONTROLLER = 0xE52d643B27601D4d2BAB2052f30cf936ed413cec;
    address constant SPARK_PROXY      = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;
    address constant CHAINLOG         = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;
    bytes32 constant OZ_DEFAULT_ADMIN_ROLE = bytes32(0);

    // Fetched from controller
    address SPARK_RATE_LIMITS;

    DssInstance  dss;
    PASInstance  pas;
    BeamState    beamState;
    Configurator configurator;
    Timelock     timelock;
    PASMom       mom;
    ChiefLike    chief;

    address pauseProxy;   // Timelock admin
    address coreCouncil;  // Has IMMEDIATE role on BeamState, proposer/canceller on Timelock
    address canceller;
    address pauser;
    address cBeam;        // Mock cBeam address

    uint256 constant MIN_DELAY = 1 days;
    bytes32 constant SALT = keccak256("integration-test");

    function setUp() public {
        // Fork mainnet at specified block
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        // Load DssInstance from chainlog
        dss = MCD.loadFromChainlog(CHAINLOG);

        // Fetch SPARK_RATE_LIMITS from controller
        SPARK_RATE_LIMITS = ControllerLike(SPARK_CONTROLLER).rateLimits();

        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");

        coreCouncil = address(0x1);
        canceller   = address(0x2);
        pauser      = address(0x3);
        cBeam       = address(0x4);

        // Deploy using PASDeploy
        pas = PASDeploy.deploy(address(this), pauseProxy, MIN_DELAY);
        // Cast to typed contracts
        beamState    = BeamState(pas.beamState);
        configurator = Configurator(pas.configurator);
        timelock     = Timelock(payable(pas.timelock));
        // Deploy Mom separately
        mom = PASMom(PASDeploy.deployMom(pauseProxy, pas.beamState, pas.timelock));

        chief = ChiefLike(dss.chainlog.getAddress("MCD_ADM"));

        // Initialize using PASInit (must be called by pauseProxy who has auth on BeamState and Timelock)
        address[] memory cancellers = new address[](1);
        cancellers[0] = canceller;

        address[] memory pausers = new address[](1);
        pausers[0] = pauser;

        vm.startPrank(pauseProxy);
        PASInit.init(pas, MIN_DELAY, coreCouncil, cancellers, pausers);
        PASInit.addCoreToChainlog(dss, pas, "PAS_STATE", "PAS_CONFIGURATOR", "PAS_TIMELOCK");
        PASInit.initMom(dss, pas, address(mom), "PAS_MOM");
        vm.stopPrank();
    }

    // ============================================================================
    // Deployment and Initialization Tests
    // ============================================================================

    function testDeploymentAddresses() public view {
        assertTrue(pas.beamState != address(0), "beamState should be deployed");
        assertTrue(pas.configurator != address(0), "configurator should be deployed");
        assertTrue(pas.timelock != address(0), "timelock should be deployed");
        assertTrue(address(mom) != address(0), "mom should be deployed");
    }

    function testConfiguratorLinkedToBeamState() public view {
        assertEq(address(configurator.beamState()), address(beamState), "configurator should reference beamState");
    }

    function testMomLinkedCorrectly() public view {
        assertEq(address(mom.beamState()), address(beamState), "mom should reference beamState");
        assertEq(address(mom.timelock()), address(timelock), "mom should reference timelock");
        assertEq(mom.owner(), pauseProxy, "mom should be owned by pauseProxy");
    }

    function testChainlogEntriesAfterInit() public view {
        assertEq(dss.chainlog.getAddress("PAS_STATE"), address(beamState), "PAS_STATE should be set in chainlog");
        assertEq(dss.chainlog.getAddress("PAS_CONFIGURATOR"), address(configurator), "PAS_CONFIGURATOR should be set in chainlog");
        assertEq(dss.chainlog.getAddress("PAS_TIMELOCK"), address(timelock), "PAS_TIMELOCK should be set in chainlog");
        assertEq(dss.chainlog.getAddress("PAS_MOM"), address(mom), "PAS_MOM should be set in chainlog");
    }

    function testBeamStateActionsConfigured() public view {
        // DELAYED role actions (timelocked)
        assertTrue(beamState.isActionInRole(BeamState.start.selector, uint8(PASInit.Role.DELAYED)), "start should be DELAYED");
        assertTrue(beamState.isActionInRole(BeamState.setHop.selector, uint8(PASInit.Role.DELAYED)), "setHop should be DELAYED");
        assertTrue(beamState.isActionInRole(BeamState.setMaxChange.selector, uint8(PASInit.Role.DELAYED)), "setMaxChange should be DELAYED");
        assertTrue(beamState.isActionInRole(BeamState.addRateLimits.selector, uint8(PASInit.Role.DELAYED)), "addRateLimits should be DELAYED");
        assertTrue(beamState.isActionInRole(BeamState.addController.selector, uint8(PASInit.Role.DELAYED)), "addController should be DELAYED");
        assertTrue(beamState.isActionInRole(BeamState.addCBeam.selector, uint8(PASInit.Role.DELAYED)), "addCBeam should be DELAYED");
        assertTrue(beamState.isActionInRole(BeamState.addInitRateLimits.selector, uint8(PASInit.Role.DELAYED)), "addInitRateLimits should be DELAYED");
        assertTrue(beamState.isActionInRole(BeamState.addInitControllerActions.selector, uint8(PASInit.Role.DELAYED)), "addInitControllerActions should be DELAYED");

        // IMMEDIATE role actions (direct)
        assertTrue(beamState.isActionInRole(BeamState.stop.selector, uint8(PASInit.Role.IMMEDIATE)), "stop should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.delRateLimits.selector, uint8(PASInit.Role.IMMEDIATE)), "delRateLimits should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.delController.selector, uint8(PASInit.Role.IMMEDIATE)), "delController should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.delCBeam.selector, uint8(PASInit.Role.IMMEDIATE)), "delCBeam should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.setCBeamForRateLimits.selector, uint8(PASInit.Role.IMMEDIATE)), "setCBeamForRateLimits should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.unsetCBeamForRateLimits.selector, uint8(PASInit.Role.IMMEDIATE)), "unsetCBeamForRateLimits should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.setCBeamForController.selector, uint8(PASInit.Role.IMMEDIATE)), "setCBeamForController should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.unsetCBeamForController.selector, uint8(PASInit.Role.IMMEDIATE)), "unsetCBeamForController should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.delInitRateLimits.selector, uint8(PASInit.Role.IMMEDIATE)), "delInitRateLimits should be IMMEDIATE");
        assertTrue(beamState.isActionInRole(BeamState.delInitControllerActions.selector, uint8(PASInit.Role.IMMEDIATE)), "delInitControllerActions should be IMMEDIATE");
    }

    function testBeamStateRolesAfterInit() public view {
        // Timelock has DELAYED role
        assertTrue(beamState.hasUserRole(address(timelock), uint8(PASInit.Role.DELAYED)), "timelock should have DELAYED role");
        // CoreCouncil has IMMEDIATE role
        assertTrue(beamState.hasUserRole(coreCouncil, uint8(PASInit.Role.IMMEDIATE)), "coreCouncil should have IMMEDIATE role");
    }

    function testTimelockRolesAfterInit() public view {
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), pauseProxy), "pauseProxy should be admin");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), coreCouncil), "coreCouncil should be proposer");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), coreCouncil), "coreCouncil should be canceller");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), canceller), "canceller should be canceller");
        assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), pauser), "pauser should be pauser");
        assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), address(mom)), "mom should be pauser");
    }

    function testMomConfigAfterInit() public view {
        assertEq(mom.owner(), pauseProxy, "mom owner should be pauseProxy");
        assertEq(mom.authority(), address(chief), "mom authority should be MCD_ADM");
        assertEq(beamState.wards(address(mom)), 1, "mom should have wards on beamState");
    }

    // The default setUp does not call setPaused, so the timelock is operational.
    function testTimelockNotPausedByDefault() public view {
        assertFalse(timelock.paused(), "timelock should not be paused by default");
    }

    // PASInit.pauseTimelock right after init brings the system up fully configured but paused: scheduling
    // is blocked until unpaused, and the admin does not retain PAUSER_ROLE (granted then revoked).
    // Timelock.unpause() then resumes it.
    function testPauseThenUnpauseTimelock() public {
        PASInstance memory freshPas = PASDeploy.deploy(address(this), pauseProxy, MIN_DELAY);
        BeamState freshBeamState = BeamState(freshPas.beamState);
        Timelock  freshTimelock  = Timelock(payable(freshPas.timelock));

        vm.startPrank(pauseProxy);
        PASInit.init(freshPas, MIN_DELAY, coreCouncil, new address[](0), new address[](0));
        PASInit.pauseTimelock(freshPas.timelock, pauseProxy);
        vm.stopPrank();

        assertTrue(freshTimelock.paused(), "timelock should be paused after setPaused(true)");
        assertFalse(freshTimelock.hasRole(freshTimelock.PAUSER_ROLE(), pauseProxy), "admin should not retain PAUSER_ROLE");
        assertTrue(freshTimelock.hasRole(freshTimelock.PROPOSER_ROLE(), coreCouncil), "coreCouncil should still be configured as proposer");

        // Configured but frozen: scheduling blocked while paused
        address[] memory targets = new address[](1);
        targets[0] = address(freshBeamState);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam);
        vm.prank(coreCouncil);
        vm.expectRevert();
        freshTimelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);

        // unpause() resumes operations (needs only DEFAULT_ADMIN_ROLE, so the admin calls it directly)
        vm.prank(pauseProxy);
        freshTimelock.unpause();
        assertFalse(freshTimelock.paused(), "timelock should be unpaused");

        vm.prank(coreCouncil);
        freshTimelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);
        bytes32 opId = freshTimelock.hashOperationBatch(targets, values, payloads, bytes32(0), SALT);
        assertTrue(freshTimelock.isOperationPending(opId), "operation should schedule after unpause");
    }

    function testInitExtras() public {
        // Deploy a fresh PAS instance for this test
        PASInstance memory freshPas = PASDeploy.deploy(address(this), pauseProxy, MIN_DELAY);
        BeamState freshBeamState = BeamState(freshPas.beamState);

        // Setup test data
        uint256 hop = 2 hours;
        uint256 maxChange = 1.5 ether; // 150% in WAD

        address[] memory testCBeams = new address[](2);
        testCBeams[0] = address(0x10);
        testCBeams[1] = address(0x11);

        address[] memory testRateLimits = new address[](2);
        testRateLimits[0] = SPARK_RATE_LIMITS;
        testRateLimits[1] = address(0x21);

        address[] memory testControllers = new address[](2);
        testControllers[0] = SPARK_CONTROLLER;
        testControllers[1] = address(0x22);

        // cBeam[0] is paired with both rateLimits and both controllers; cBeam[1] gets only the second rateLimits
        InitCBeamConfig[] memory cBeamConfigs = new InitCBeamConfig[](2);
        cBeamConfigs[0] = InitCBeamConfig({
            cBeam:       testCBeams[0],
            rateLimits:  testRateLimits,
            controllers: testControllers
        });
        address[] memory cBeam1RateLimits = new address[](1);
        cBeam1RateLimits[0] = testRateLimits[1];
        cBeamConfigs[1] = InitCBeamConfig({
            cBeam:       testCBeams[1],
            rateLimits:  cBeam1RateLimits,
            controllers: new address[](0)
        });

        vm.startPrank(pauseProxy);
        PASInit.initExtras(freshPas, hop, maxChange, testRateLimits, testControllers, cBeamConfigs);
        vm.stopPrank();

        // Verify default hop and maxChange are set
        assertEq(freshBeamState.getHop(address(0)), hop, "default hop should be set");
        assertEq(freshBeamState.getMaxChange(address(0)), maxChange, "default maxChange should be set");

        // Verify rateLimits are added
        assertEq(freshBeamState.rateLimits(testRateLimits[0]), 1, "first rateLimits should be added");
        assertEq(freshBeamState.rateLimits(testRateLimits[1]), 1, "second rateLimits should be added");

        // Verify controllers are added
        assertEq(freshBeamState.controllers(testControllers[0]), 1, "first controller should be added");
        assertEq(freshBeamState.controllers(testControllers[1]), 1, "second controller should be added");

        // Verify cBeams are added
        assertEq(freshBeamState.cBeams(testCBeams[0]), 1, "first cBeam should be added");
        assertEq(freshBeamState.cBeams(testCBeams[1]), 1, "second cBeam should be added");

        // Verify cBeam pairings
        assertEq(freshBeamState.rateLimitsCBeams(testRateLimits[0], testCBeams[0]), 1, "cBeam0<->rateLimits0 paired");
        assertEq(freshBeamState.rateLimitsCBeams(testRateLimits[1], testCBeams[0]), 1, "cBeam0<->rateLimits1 paired");
        assertEq(freshBeamState.controllersCBeams(testControllers[0], testCBeams[0]), 1, "cBeam0<->controller0 paired");
        assertEq(freshBeamState.controllersCBeams(testControllers[1], testCBeams[0]), 1, "cBeam0<->controller1 paired");
        assertEq(freshBeamState.rateLimitsCBeams(testRateLimits[0], testCBeams[1]), 0, "cBeam1<->rateLimits0 not paired");
        assertEq(freshBeamState.rateLimitsCBeams(testRateLimits[1], testCBeams[1]), 1, "cBeam1<->rateLimits1 paired");
        assertEq(freshBeamState.controllersCBeams(testControllers[0], testCBeams[1]), 0, "cBeam1<->controller0 not paired");
        assertEq(freshBeamState.controllersCBeams(testControllers[1], testCBeams[1]), 0, "cBeam1<->controller1 not paired");
    }

    function initExtras() external {
        PASInstance memory freshPas = PASDeploy.deploy(address(this), address(this), MIN_DELAY);
        PASInit.initExtras(freshPas, 0, 1.5 ether, new address[](0), new address[](0), new InitCBeamConfig[](0));
    }

    function testInitExtrasRevertsWhenHopIsZero() public {
        vm.expectRevert("PASInit/hop-is-zero");
        this.initExtras();
    }

    function testInitLimitsAndControllerData() public {
        PASInstance memory freshPas = PASDeploy.deploy(address(this), pauseProxy, MIN_DELAY);

        // Setup rate limit configs
        InitRateLimitConfig[] memory rlConfigs = new InitRateLimitConfig[](2);
        rlConfigs[0] = InitRateLimitConfig({
            key:        bytes32(0),
            rateLimits: SPARK_RATE_LIMITS,
            maxAmount:  1_000_000 ether,
            slope:      100 ether
        });
        rlConfigs[1] = InitRateLimitConfig({
            key:        bytes32(uint256(1)),
            rateLimits: address(0x42),
            maxAmount:  500_000 ether,
            slope:      50 ether
        });

        // Setup controller action configs
        bytes memory actionData1 = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(123));
        bytes memory actionData2 = abi.encodeWithSelector(bytes4(0xcafebabe), address(0x99));
        InitControllerActionConfig[] memory caConfigs = new InitControllerActionConfig[](2);
        caConfigs[0] = InitControllerActionConfig({data: actionData1, controller: SPARK_CONTROLLER});
        caConfigs[1] = InitControllerActionConfig({data: actionData2, controller: address(0)});

        BeamState freshBeamState = BeamState(freshPas.beamState);

        vm.startPrank(pauseProxy);
        PASInit.initLimitsAndControllerData(freshPas, rlConfigs, caConfigs);
        vm.stopPrank();

        // Verify init rate limits
        (uint256 maxAmount0, uint256 slope0) = freshBeamState.initRateLimits(bytes32(0), SPARK_RATE_LIMITS);
        assertEq(maxAmount0, 1_000_000 ether, "first rate limit maxAmount");
        assertEq(slope0, 100 ether, "first rate limit slope");

        (uint256 maxAmount1, uint256 slope1) = freshBeamState.initRateLimits(bytes32(uint256(1)), address(0x42));
        assertEq(maxAmount1, 500_000 ether, "second rate limit maxAmount");
        assertEq(slope1, 50 ether, "second rate limit slope");

        // Verify init controller actions
        assertEq(freshBeamState.initControllerActions(keccak256(actionData1), SPARK_CONTROLLER), 1, "first controller action");
        assertEq(freshBeamState.initControllerActions(keccak256(actionData2), address(0)), 1, "second controller action");
    }

    // ============================================================================
    // CoreCouncil Direct Actions (IMMEDIATE Role) Tests
    // ============================================================================

    function testCoreCouncilCanStop() public {
        assertFalse(beamState.stopped(), "should not be stopped initially");

        vm.prank(coreCouncil);
        beamState.stop();

        assertTrue(beamState.stopped(), "should be stopped after coreCouncil calls stop");
    }

    function testCoreCouncilCanDelRateLimits() public {
        // Setup: pauseProxy adds rateLimits
        vm.prank(pauseProxy);
        beamState.addRateLimits(SPARK_RATE_LIMITS);
        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 1, "rateLimits should be added");

        // CoreCouncil can delete (role 2)
        vm.prank(coreCouncil);
        beamState.delRateLimits(SPARK_RATE_LIMITS);

        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 0, "rateLimits should be deleted");
    }

    function testCoreCouncilCanDelController() public {
        // Setup: pauseProxy adds controller
        vm.prank(pauseProxy);
        beamState.addController(SPARK_CONTROLLER);
        assertEq(beamState.controllers(SPARK_CONTROLLER), 1, "controller should be added");

        // CoreCouncil can delete (role 2)
        vm.prank(coreCouncil);
        beamState.delController(SPARK_CONTROLLER);

        assertEq(beamState.controllers(SPARK_CONTROLLER), 0, "controller should be deleted");
    }

    function testCoreCouncilCanDelCBeam() public {
        // pauseProxy adds cBeam directly (has auth/wards)
        vm.prank(pauseProxy);
        beamState.addCBeam(cBeam);
        assertEq(beamState.cBeams(cBeam), 1, "cBeam should be added");

        // CoreCouncil can delete (role 2 action)
        vm.prank(coreCouncil);
        beamState.delCBeam(cBeam);
        assertEq(beamState.cBeams(cBeam), 0, "cBeam should be deleted");
    }

    function testCoreCouncilCanSetAndUnsetCBeamForRateLimits() public {
        // Setup: pauseProxy adds rateLimits and cBeam, then sets association
        vm.startPrank(pauseProxy);
        beamState.addRateLimits(SPARK_RATE_LIMITS);
        beamState.addCBeam(cBeam);
        vm.stopPrank();

        vm.prank(coreCouncil);
        beamState.setCBeamForRateLimits(SPARK_RATE_LIMITS, cBeam);
        assertEq(beamState.rateLimitsCBeams(SPARK_RATE_LIMITS, cBeam), 1, "cBeam should be set");

        // CoreCouncil can unset association (role 2)
        vm.prank(coreCouncil);
        beamState.unsetCBeamForRateLimits(SPARK_RATE_LIMITS, cBeam);
        assertEq(beamState.rateLimitsCBeams(SPARK_RATE_LIMITS, cBeam), 0, "cBeam should be unset for rateLimits");
    }

    function testCoreCouncilCanSetAndUnsetCBeamForController() public {
        // Setup: pauseProxy adds controller and cBeam, then sets association
        vm.startPrank(pauseProxy);
        beamState.addController(SPARK_CONTROLLER);
        beamState.addCBeam(cBeam);
        vm.stopPrank();

        vm.prank(coreCouncil);
        beamState.setCBeamForController(SPARK_CONTROLLER, cBeam);
        assertEq(beamState.controllersCBeams(SPARK_CONTROLLER, cBeam), 1, "cBeam should be set");

        // CoreCouncil can unset association (role 2)
        vm.prank(coreCouncil);
        beamState.unsetCBeamForController(SPARK_CONTROLLER, cBeam);

        assertEq(beamState.controllersCBeams(SPARK_CONTROLLER, cBeam), 0, "cBeam should be unset for controller");
    }

    function testCoreCouncilCanDelInitRateLimits() public {
        bytes32 key = keccak256("test-rate-limit-key");

        // Setup: pauseProxy adds init rate limits
        vm.prank(pauseProxy);
        beamState.addInitRateLimits(key, SPARK_RATE_LIMITS, 1_000 ether, 100 ether);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, SPARK_RATE_LIMITS);
        assertEq(limits.maxAmount, 1_000 ether, "maxAmount should be set");
        assertEq(limits.slope, 100 ether, "slope should be set");

        // CoreCouncil can delete (role 2)
        vm.prank(coreCouncil);
        beamState.delInitRateLimits(key, SPARK_RATE_LIMITS);
        limits = beamState.getInitRateLimits(key, SPARK_RATE_LIMITS);
        assertEq(limits.maxAmount, 0, "maxAmount should be deleted");
        assertEq(limits.slope, 0, "slope should be deleted");
    }

    function testCoreCouncilCanDelInitControllerActions() public {
        bytes memory actionData = abi.encodeWithSignature("someAction(uint256)", 42);

        // Setup: pauseProxy adds init controller action
        vm.prank(pauseProxy);
        bytes32 key = beamState.addInitControllerActions(actionData, SPARK_CONTROLLER);

        assertTrue(beamState.isControllerActionEnabled(key, SPARK_CONTROLLER), "action should be enabled");

        // CoreCouncil can delete (role 2)
        vm.prank(coreCouncil);
        beamState.delInitControllerActions(key, SPARK_CONTROLLER);
        assertFalse(beamState.isControllerActionEnabled(key, SPARK_CONTROLLER), "action should be disabled");
    }

    function testNonAuthorizedCannotDoRole2Actions() public {
        address unauthorized = address(0x999);

        vm.prank(unauthorized);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.stop();
    }

    // ============================================================================
    // Timelock Flow Tests (DELAYED Role Actions)
    // ============================================================================

    function _scheduleAndExecute(bytes memory payload, bytes32 salt) internal {
        address[] memory targets = new address[](1);
        targets[0] = address(beamState);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;

        vm.prank(coreCouncil);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function testTimelockCanStart() public {
        // First stop via coreCouncil (role 2)
        vm.prank(coreCouncil);
        beamState.stop();
        assertTrue(beamState.stopped(), "should be stopped");

        // Schedule and execute start via timelock (role 1)
        _scheduleAndExecute(abi.encodeWithSelector(BeamState.start.selector), keccak256("start"));

        assertFalse(beamState.stopped(), "should be started via timelock");
    }

    function testTimelockCanSetHop() public {
        uint256 newHop = 4 hours;

        _scheduleAndExecute(
            abi.encodeWithSelector(BeamState.setHop.selector, address(0), newHop),
            keccak256("setHop")
        );

        assertEq(beamState.getHop(address(0)), newHop, "hop should be set via timelock");
    }

    function testTimelockCanSetMaxChange() public {
        uint256 newMaxChange = 2 ether; // 200% in WAD

        _scheduleAndExecute(
            abi.encodeWithSelector(BeamState.setMaxChange.selector, address(0), newMaxChange),
            keccak256("setMaxChange")
        );

        assertEq(beamState.getMaxChange(address(0)), newMaxChange, "maxChange should be set via timelock");
    }

    function testTimelockCanAddRateLimits() public {
        address newRateLimits = address(0xA1);

        _scheduleAndExecute(
            abi.encodeWithSelector(BeamState.addRateLimits.selector, newRateLimits),
            keccak256("addRateLimits")
        );

        assertEq(beamState.rateLimits(newRateLimits), 1, "rateLimits should be added via timelock");
    }

    function testTimelockCanAddController() public {
        address newController = address(0xC0);

        _scheduleAndExecute(
            abi.encodeWithSelector(BeamState.addController.selector, newController),
            keccak256("addController")
        );

        assertEq(beamState.controllers(newController), 1, "controller should be added via timelock");
    }

    function testTimelockCanAddCBeam() public {
        _scheduleAndExecute(
            abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam),
            keccak256("addCBeam")
        );

        assertEq(beamState.cBeams(cBeam), 1, "cBeam should be added via timelock");
    }

    function testTimelockCanAddInitRateLimits() public {
        bytes32 key = keccak256("test-key");
        uint256 maxAmount = 1_000 ether;
        uint256 slope = 100 ether;

        _scheduleAndExecute(
            abi.encodeWithSelector(BeamState.addInitRateLimits.selector, key, SPARK_RATE_LIMITS, maxAmount, slope),
            keccak256("addInitRateLimits")
        );

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, SPARK_RATE_LIMITS);
        assertEq(limits.maxAmount, maxAmount, "maxAmount should be set via timelock");
        assertEq(limits.slope, slope, "slope should be set via timelock");
    }

    function testTimelockCanAddInitControllerActions() public {
        bytes memory actionData = abi.encodeWithSignature("someAction(uint256)", 42);

        _scheduleAndExecute(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, actionData, SPARK_CONTROLLER),
            keccak256("addInitControllerActions")
        );

        bytes32 key = keccak256(actionData);
        assertTrue(beamState.isControllerActionEnabled(key, SPARK_CONTROLLER), "action should be enabled via timelock");
    }

    // ============================================================================
    // Cancellation Tests
    // ============================================================================

    function testCoreCouncilCanCancelOperation() public {
        // Schedule operation
        bytes32 operationId = _scheduleDirect(
            abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam),
            bytes32(0),
            SALT
        );

        assertTrue(timelock.isOperationPending(operationId), "operation should be pending");

        // Cancel
        vm.prank(coreCouncil);
        timelock.cancel(operationId);

        assertFalse(timelock.isOperationPending(operationId), "operation should be cancelled");
        assertEq(timelock.getOperationsCount(), 0, "operation count should be 0");
    }

    function testCancellerCanCancelOperation() public {
        bytes32 operationId = _scheduleDirect(
            abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam),
            bytes32(0),
            SALT
        );

        vm.prank(canceller);
        timelock.cancel(operationId);

        assertFalse(timelock.isOperationPending(operationId), "operation should be cancelled by canceller");
    }

    // ============================================================================
    // Pausing Tests
    // ============================================================================

    function testPauserCanPauseTimelock() public {
        vm.prank(pauser);
        timelock.pause();

        assertTrue(timelock.paused(), "timelock should be paused");
    }

    function testPausedTimelockBlocksScheduling() public {
        vm.prank(pauser);
        timelock.pause();

        address[] memory targets = new address[](1);
        targets[0] = address(beamState);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam);

        vm.prank(coreCouncil);
        vm.expectRevert();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);
    }

    function testPausedTimelockBlocksExecution() public {
        // Schedule first
        bytes32 operationId = _scheduleDirect(
            abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam),
            bytes32(0),
            SALT
        );

        vm.warp(block.timestamp + MIN_DELAY);

        // Pause
        vm.prank(pauser);
        timelock.pause();

        // Try to execute
        Timelock.Operation memory op = timelock.getOperation(operationId);
        vm.expectRevert();
        timelock.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
    }

    function testAdminCanUnpause() public {
        vm.prank(pauser);
        timelock.pause();

        vm.prank(pauseProxy);
        timelock.unpause();

        assertFalse(timelock.paused(), "timelock should be unpaused");
    }

    function testPauserCannotUnpause() public {
        vm.prank(pauser);
        timelock.pause();

        vm.prank(pauser);
        vm.expectRevert();
        timelock.unpause();
    }

    // ============================================================================
    // Predecessor Chain Tests
    // ============================================================================

    function testOperationsWithPredecessor() public {
        // Schedule first operation: addRateLimits
        bytes memory payload1 = abi.encodeWithSelector(BeamState.addRateLimits.selector, SPARK_RATE_LIMITS);
        address[] memory targets = new address[](1);
        targets[0] = address(beamState);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads1 = new bytes[](1);
        payloads1[0] = payload1;

        vm.prank(coreCouncil);
        timelock.scheduleBatch(targets, values, payloads1, bytes32(0), keccak256("op1"), MIN_DELAY);
        bytes32 id1 = timelock.hashOperationBatch(targets, values, payloads1, bytes32(0), keccak256("op1"));

        // Schedule second operation: addController with predecessor
        bytes memory payload2 = abi.encodeWithSelector(BeamState.addController.selector, SPARK_CONTROLLER);
        bytes[] memory payloads2 = new bytes[](1);
        payloads2[0] = payload2;

        vm.prank(coreCouncil);
        timelock.scheduleBatch(targets, values, payloads2, id1, keccak256("op2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Try to execute second before first - should fail
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads2, id1, keccak256("op2"));

        // Execute first
        timelock.executeBatch(targets, values, payloads1, bytes32(0), keccak256("op1"));
        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 1, "rateLimits should be added");

        // Now execute second
        timelock.executeBatch(targets, values, payloads2, id1, keccak256("op2"));
        assertEq(beamState.controllers(SPARK_CONTROLLER), 1, "controller should be added");
    }

    // ============================================================================
    // Full Workflow Test
    // ============================================================================

    function testFullOnboardingWorkflow() public {
        // 1. CoreCouncil schedules adding a cBeam via timelock
        bytes32 addCBeamOp = _scheduleDirect(
            abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam),
            bytes32(0),
            keccak256("step1")
        );

        // 2. Schedule addRateLimits with predecessor
        bytes32 addRateLimitsOp = _scheduleDirect(
            abi.encodeWithSelector(BeamState.addRateLimits.selector, SPARK_RATE_LIMITS),
            addCBeamOp,
            keccak256("step2")
        );

        // 3. Schedule setHop with predecessor
        bytes32 setHopOp = _scheduleDirect(
            abi.encodeWithSelector(BeamState.setHop.selector, SPARK_RATE_LIMITS, 4 hours),
            addRateLimitsOp,
            keccak256("step3")
        );

        // Wait for delay
        vm.warp(block.timestamp + MIN_DELAY);

        // 4. Execute in order
        Timelock.Operation memory op1 = timelock.getOperation(addCBeamOp);
        timelock.executeBatch(op1.targets, op1.values, op1.payloads, op1.predecessor, op1.salt);
        assertEq(beamState.cBeams(cBeam), 1, "cBeam added");

        Timelock.Operation memory op2 = timelock.getOperation(addRateLimitsOp);
        timelock.executeBatch(op2.targets, op2.values, op2.payloads, op2.predecessor, op2.salt);
        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 1, "rateLimits added");

        Timelock.Operation memory op3 = timelock.getOperation(setHopOp);
        timelock.executeBatch(op3.targets, op3.values, op3.payloads, op3.predecessor, op3.salt);
        assertEq(beamState.getHop(SPARK_RATE_LIMITS), 4 hours, "hop set");

        // 5. CoreCouncil can now directly set cBeam for rateLimits (role 2)
        vm.prank(coreCouncil);
        beamState.setCBeamForRateLimits(SPARK_RATE_LIMITS, cBeam);
        assertEq(beamState.rateLimitsCBeams(SPARK_RATE_LIMITS, cBeam), 1, "cBeam associated with rateLimits");

        // 6. Emergency stop by coreCouncil (direct, no timelock)
        vm.prank(coreCouncil);
        beamState.stop();
        assertTrue(beamState.stopped(), "system stopped");

        // 7. Restart requires timelock
        bytes32 startOp = _scheduleDirect(
            abi.encodeWithSelector(BeamState.start.selector),
            bytes32(0),
            keccak256("restart")
        );

        vm.warp(block.timestamp + MIN_DELAY);

        Timelock.Operation memory restartOp = timelock.getOperation(startOp);
        timelock.executeBatch(restartOp.targets, restartOp.values, restartOp.payloads, restartOp.predecessor, restartOp.salt);
        assertFalse(beamState.stopped(), "system restarted");
    }

    // ============================================================================
    // Admin Delay Change Test
    // ============================================================================

    function testAdminCanChangeDelayImmediately() public {
        uint256 newDelay = 2 days;

        vm.prank(pauseProxy);
        timelock.updateDelayImmediately(newDelay);

        assertEq(timelock.getMinDelay(), newDelay, "delay should be updated immediately");
    }

    function testNonAdminCannotChangeDelay() public {
        vm.prank(coreCouncil);
        vm.expectRevert();
        timelock.updateDelayImmediately(2 days);
    }

    // ============================================================================
    // PASMom Integration Tests
    // ============================================================================

    function testMomOwnerCanStopBeamState() public {
        assertFalse(beamState.stopped(), "should not be stopped initially");

        vm.prank(pauseProxy);
        mom.stop();

        assertTrue(beamState.stopped(), "beamState should be stopped via mom");
    }

    function testMomOwnerCanPauseTimelock() public {
        assertFalse(timelock.paused(), "timelock should not be paused initially");

        vm.prank(pauseProxy);
        mom.pause();

        assertTrue(timelock.paused(), "timelock should be paused via mom");
    }

    function testMomHatCanStopBeamState() public {
        address hat = chief.hat();
        assertFalse(beamState.stopped(), "should not be stopped initially");

        vm.prank(hat);
        mom.stop();

        assertTrue(beamState.stopped(), "beamState should be stopped via mom by hat");
    }

    function testMomHatCanPauseTimelock() public {
        address hat = chief.hat();
        assertFalse(timelock.paused(), "timelock should not be paused initially");

        vm.prank(hat);
        mom.pause();

        assertTrue(timelock.paused(), "timelock should be paused via mom by hat");
    }

    function testMomUnauthorizedCannotStop() public {
        address unauthorized = address(0x999);

        vm.prank(unauthorized);
        vm.expectRevert("PASMom/not-authorized");
        mom.stop();
    }

    function testMomUnauthorizedCannotPause() public {
        address unauthorized = address(0x999);

        vm.prank(unauthorized);
        vm.expectRevert("PASMom/not-authorized");
        mom.pause();
    }

    function testMomEmergencyStopBlocksOperations() public {
        // Setup: onboard a cBeam and associate it with rateLimits
        bytes32 rateLimitKey = keccak256("mom-test-key");

        vm.startPrank(pauseProxy);
        beamState.addCBeam(cBeam);
        beamState.addRateLimits(SPARK_RATE_LIMITS);
        beamState.addInitRateLimits(rateLimitKey, SPARK_RATE_LIMITS, 1_000_000e18, 100_000e18);
        beamState.setHop(SPARK_RATE_LIMITS, 1 hours); // Set hop for rate limit increases
        vm.stopPrank();

        vm.prank(coreCouncil);
        beamState.setCBeamForRateLimits(SPARK_RATE_LIMITS, cBeam);

        // Grant configurator admin role
        vm.prank(SPARK_PROXY);
        RateLimitsWithRolesLike(SPARK_RATE_LIMITS).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));

        // cBeam can operate normally
        vm.prank(cBeam);
        configurator.setRateLimit(SPARK_RATE_LIMITS, rateLimitKey, 500_000e18, 50_000e18);

        // Hat triggers emergency stop via mom
        address hat = chief.hat();
        vm.prank(hat);
        mom.stop();

        // cBeam operations are now blocked
        vm.prank(cBeam);
        vm.expectRevert("Configurator/stopped");
        configurator.setRateLimit(SPARK_RATE_LIMITS, rateLimitKey, 400_000e18, 40_000e18);
    }

    function testMomPauseBlocksTimelockScheduling() public {
        // Hat pauses timelock via mom
        address hat = chief.hat();
        vm.prank(hat);
        mom.pause();

        // Scheduling via timelock is blocked
        address[] memory targets = new address[](1);
        targets[0] = address(beamState);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam);

        vm.prank(coreCouncil);
        vm.expectRevert();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);
    }

    function testMomPauseBlocksTimelockExecution() public {
        // Schedule an operation first
        bytes32 operationId = _scheduleDirect(
            abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam),
            bytes32(0),
            SALT
        );

        vm.warp(block.timestamp + MIN_DELAY);

        // Hat pauses timelock via mom
        address hat = chief.hat();
        vm.prank(hat);
        mom.pause();

        // Execution is blocked
        Timelock.Operation memory op = timelock.getOperation(operationId);
        vm.expectRevert();
        timelock.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
    }

    // ============================================================================
    // Post-Onboarding cBeam Operations Test with Real Contracts
    // ============================================================================

    function _scheduleDirect(bytes memory payload, bytes32 predecessor, bytes32 salt) internal returns (bytes32) {
        address[] memory targets = new address[](1);
        targets[0] = address(beamState);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;

        vm.prank(coreCouncil);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, MIN_DELAY);

        return timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
    }

    function testCBeamCanOperateAfterOnboarding() public {
        bytes32 rateLimitKey = keccak256("integration-test-key");

        // Controller action: setMintRecipient for domain 6
        address testRecipient = address(0xDEADBEEF);
        bytes memory setMintRecipientAction = abi.encodeWithSelector(
            ControllerLike.setMintRecipient.selector,
            uint32(6),  // domain
            bytes32(uint256(uint160(testRecipient)))
        );

        // ========================================
        // Phase 0: Init some defaults via spell (PASInit.initLimitsAndControllerData)
        // ========================================
        bytes32 spellRateLimitKey = keccak256("spell-init-key");
        bytes memory spellControllerAction = abi.encodeWithSelector(
            ControllerLike.setMintRecipient.selector,
            uint32(7),  // different domain than the timelock-onboarded action
            bytes32(uint256(uint160(testRecipient)))
        );
        {
            InitRateLimitConfig[] memory rlConfigs = new InitRateLimitConfig[](1);
            rlConfigs[0] = InitRateLimitConfig({
                key:        spellRateLimitKey,
                rateLimits: SPARK_RATE_LIMITS,
                maxAmount:  2_000_000e18,
                slope:      200_000e18
            });

            InitControllerActionConfig[] memory caConfigs = new InitControllerActionConfig[](1);
            caConfigs[0] = InitControllerActionConfig({data: spellControllerAction, controller: SPARK_CONTROLLER});

            vm.startPrank(pauseProxy);
            PASInit.initLimitsAndControllerData(pas, rlConfigs, caConfigs);
            vm.stopPrank();
        }

        // ========================================
        // Phase 1: Onboard via Timelock (Role 1)
        // ========================================
        bytes32[] memory opIds = new bytes32[](7);
        {
            // 1a. Schedule addCBeam
            opIds[0] = _scheduleDirect(
                abi.encodeWithSelector(BeamState.addCBeam.selector, cBeam),
                bytes32(0), keccak256("addCBeam")
            );

            // 1b. Schedule addRateLimits for SPARK_RATE_LIMITS
            opIds[1] = _scheduleDirect(
                abi.encodeWithSelector(BeamState.addRateLimits.selector, SPARK_RATE_LIMITS),
                opIds[0], keccak256("addRateLimits")
            );

            // 1c. Schedule addController for SPARK_CONTROLLER
            opIds[2] = _scheduleDirect(
                abi.encodeWithSelector(BeamState.addController.selector, SPARK_CONTROLLER),
                opIds[1], keccak256("addController")
            );

            // 1d. Schedule setHop for rateLimits
            opIds[3] = _scheduleDirect(
                abi.encodeWithSelector(BeamState.setHop.selector, SPARK_RATE_LIMITS, 1 hours),
                opIds[2], keccak256("setHop")
            );

            // 1e. Schedule setMaxChange for rateLimits
            opIds[4] = _scheduleDirect(
                abi.encodeWithSelector(BeamState.setMaxChange.selector, SPARK_RATE_LIMITS, 2 ether),
                opIds[3], keccak256("setMaxChange")
            );

            // 1f. Schedule addInitRateLimits
            opIds[5] = _scheduleDirect(
                abi.encodeWithSelector(BeamState.addInitRateLimits.selector, rateLimitKey, SPARK_RATE_LIMITS, uint256(1_000_000e18), uint256(100_000e18)),
                opIds[4], keccak256("addInitRateLimits")
            );

            // 1g. Schedule addInitControllerActions
            opIds[6] = _scheduleDirect(
                abi.encodeWithSelector(BeamState.addInitControllerActions.selector, setMintRecipientAction, SPARK_CONTROLLER),
                opIds[5], keccak256("addInitControllerActions")
            );
        }

        // Wait for delay
        vm.warp(block.timestamp + MIN_DELAY);

        // Execute all operations in order
        for (uint256 i = 0; i < opIds.length; i++) {
            Timelock.Operation memory op = timelock.getOperation(opIds[i]);
            timelock.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
        }

        // Verify onboarding results
        assertEq(beamState.cBeams(cBeam), 1, "cBeam should be added");
        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 1, "rateLimits should be added");
        assertEq(beamState.controllers(SPARK_CONTROLLER), 1, "controller should be added");
        assertEq(beamState.getHop(SPARK_RATE_LIMITS), 1 hours, "hop should be set");
        assertEq(beamState.getMaxChange(SPARK_RATE_LIMITS), 2 ether, "maxChange should be set");
        {
            BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(rateLimitKey, SPARK_RATE_LIMITS);
            assertEq(limits.maxAmount, 1_000_000e18, "init rate limit maxAmount should be set");
            assertEq(limits.slope, 100_000e18, "init rate limit slope should be set");
        }
        assertTrue(beamState.isControllerActionEnabled(keccak256(setMintRecipientAction), SPARK_CONTROLLER), "controller action should be enabled");
        // Verify spell-configured defaults
        {
            BeamState.DefaultRateLimits memory spellLimits = beamState.getInitRateLimits(spellRateLimitKey, SPARK_RATE_LIMITS);
            assertEq(spellLimits.maxAmount, 2_000_000e18, "spell init rate limit maxAmount should be set");
            assertEq(spellLimits.slope, 200_000e18, "spell init rate limit slope should be set");
        }
        assertTrue(beamState.isControllerActionEnabled(keccak256(spellControllerAction), SPARK_CONTROLLER), "spell controller action should be enabled");

        // ========================================
        // Phase 2: Grant admin role to configurator and associate cBeam (Role 2 - direct)
        // ========================================

        // Grant OZ_DEFAULT_ADMIN_ROLE to configurator on both controller and rate limits
        // This allows configurator to call functions on these contracts
        vm.startPrank(SPARK_PROXY);
        ControllerLike(SPARK_CONTROLLER).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));
        RateLimitsWithRolesLike(SPARK_RATE_LIMITS).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));
        vm.stopPrank();

        vm.startPrank(coreCouncil);
        beamState.setCBeamForRateLimits(SPARK_RATE_LIMITS, cBeam);
        beamState.setCBeamForController(SPARK_CONTROLLER, cBeam);
        vm.stopPrank();

        assertEq(beamState.rateLimitsCBeams(SPARK_RATE_LIMITS, cBeam), 1, "cBeam should be associated with rateLimits");
        assertEq(beamState.controllersCBeams(SPARK_CONTROLLER, cBeam), 1, "cBeam should be associated with controller");

        // ========================================
        // Phase 3: cBeam operates via Configurator
        // ========================================

        // 3a. cBeam sets rate limit
        vm.prank(cBeam);
        configurator.setRateLimit(SPARK_RATE_LIMITS, rateLimitKey, 500_000e18, 50_000e18);
        {
            RateLimitsLike.RateLimitData memory data = RateLimitsLike(SPARK_RATE_LIMITS).getRateLimitData(rateLimitKey);
            assertEq(data.maxAmount, 500_000e18, "rate limit maxAmount should be set by cBeam on real contract");
            assertEq(data.slope, 50_000e18, "rate limit slope should be set by cBeam on real contract");
        }

        // 3b. cBeam calls controller action
        vm.prank(cBeam);
        configurator.callControllerAction(SPARK_CONTROLLER, setMintRecipientAction);

        // Verify
        bytes32 expectedRecipient = bytes32(uint256(uint160(testRecipient)));
        assertEq(ControllerLike(SPARK_CONTROLLER).mintRecipients(6), expectedRecipient, "mintRecipient should be set on real controller");

        // 3c. cBeam sets rate limit using spell-configured defaults
        vm.prank(cBeam);
        configurator.setRateLimit(SPARK_RATE_LIMITS, spellRateLimitKey, 1_500_000e18, 150_000e18);
        {
            RateLimitsLike.RateLimitData memory data = RateLimitsLike(SPARK_RATE_LIMITS).getRateLimitData(spellRateLimitKey);
            assertEq(data.maxAmount, 1_500_000e18, "spell rate limit maxAmount should be set by cBeam on real contract");
            assertEq(data.slope, 150_000e18, "spell rate limit slope should be set by cBeam on real contract");
        }

        // 3d. cBeam calls spell-configured controller action
        vm.prank(cBeam);
        configurator.callControllerAction(SPARK_CONTROLLER, spellControllerAction);
        assertEq(ControllerLike(SPARK_CONTROLLER).mintRecipients(7), expectedRecipient, "spell mintRecipient should be set on real controller");

        // ========================================
        // Phase 4: Verify restrictions
        // ========================================

        // 4a. Unauthorized cBeam cannot set rate limit
        address unauthorizedCBeam = address(0x999);
        vm.prank(unauthorizedCBeam);
        vm.expectRevert("Configurator/not-authorized-ratelimits-cBeam");
        configurator.setRateLimit(SPARK_RATE_LIMITS, rateLimitKey, 100_000e18, 10_000e18);

        // 4b. Unauthorized cBeam cannot call controller action
        vm.prank(unauthorizedCBeam);
        vm.expectRevert("Configurator/not-authorized-controller-cBeam");
        configurator.callControllerAction(SPARK_CONTROLLER, setMintRecipientAction);

        // 4c. cBeam cannot call non-whitelisted action
        bytes memory nonWhitelistedAction = abi.encodeWithSelector(
            ControllerLike.setMintRecipient.selector,
            uint32(8),  // domain not whitelisted by either timelock or spell
            bytes32(uint256(uint160(testRecipient)))
        );
        vm.prank(cBeam);
        vm.expectRevert("Configurator/not-valid-data");
        configurator.callControllerAction(SPARK_CONTROLLER, nonWhitelistedAction);

        // 4d. Operations blocked when stopped
        vm.prank(coreCouncil);
        beamState.stop();

        vm.prank(cBeam);
        vm.expectRevert("Configurator/stopped");
        configurator.setRateLimit(SPARK_RATE_LIMITS, rateLimitKey, 400_000e18, 40_000e18);

        vm.prank(cBeam);
        vm.expectRevert("Configurator/stopped");
        configurator.callControllerAction(SPARK_CONTROLLER, setMintRecipientAction);

        // 4e. Operations resume after restart (via timelock)
        bytes32 startOp = _scheduleDirect(
            abi.encodeWithSelector(BeamState.start.selector),
            bytes32(0),
            keccak256("restart")
        );

        vm.warp(block.timestamp + MIN_DELAY);
        {
            Timelock.Operation memory op = timelock.getOperation(startOp);
            timelock.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
        }

        assertFalse(beamState.stopped(), "system should be running");

        // cBeam can operate again on real contracts
        vm.prank(cBeam);
        configurator.setRateLimit(SPARK_RATE_LIMITS, rateLimitKey, 400_000e18, 40_000e18);
        {
            RateLimitsLike.RateLimitData memory data = RateLimitsLike(SPARK_RATE_LIMITS).getRateLimitData(rateLimitKey);
            assertEq(data.maxAmount, 400_000e18, "rate limit should be updated after restart on real contract");
        }
    }
}
