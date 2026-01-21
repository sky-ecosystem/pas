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

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";
import { PASInstance } from "deploy/PASInstance.sol";
import { PASDeploy } from "deploy/PASDeploy.sol";
import { PASInit } from "deploy/PASInit.sol";
import { BeamState } from "src/BeamState.sol";
import { Configurator, RateLimitsLike } from "src/Configurator.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { TimelockWrapper, RateLimitConfig } from "src/timelock/TimelockWrapper.sol";

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
    uint256 constant FORK_BLOCK       = 24250000;
    bytes32 constant OZ_DEFAULT_ADMIN_ROLE = bytes32(0);

    // Fetched from controller
    address public SPARK_RATE_LIMITS;

    PASInstance     public pas;
    BeamState       public beamState;
    Configurator    public configurator;
    Timelock        public timelock;
    TimelockWrapper public timelockWrapper;

    address public deployer;
    address public owner;        // Timelock admin
    address public coreCouncil;  // Has role 2 on BeamState, proposer/canceller on Timelock
    address public canceller;
    address public pauser;
    address public cBeam;        // Mock cBeam address

    uint256 public constant MIN_DELAY = 1 days;
    bytes32 public constant SALT = keccak256("integration-test");

    // Events
    event CallScheduled(
        bytes32 indexed id,
        uint256 indexed index,
        address target,
        uint256 value,
        bytes data,
        bytes32 predecessor,
        uint256 delay
    );
    event CallExecuted(bytes32 indexed id, uint256 indexed index, address target, uint256 value, bytes data);
    event Cancelled(bytes32 indexed id);
    event Paused(address account);
    event Unpaused(address account);
    event ProposalSubmitted(bytes32 indexed operationId, string functionName);

    function setUp() public {
        // Fork mainnet at specified block
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        // Fetch SPARK_RATE_LIMITS from controller
        SPARK_RATE_LIMITS = ControllerLike(SPARK_CONTROLLER).rateLimits();

        deployer    = address(this);
        owner       = address(0x1);
        coreCouncil = address(0x2);
        canceller   = address(0x3);
        pauser      = address(0x4);
        cBeam       = address(0x5);

        // Deploy using PASDeploy
        pas = PASDeploy.deploy(deployer, owner, MIN_DELAY);

        // Cast to typed contracts
        beamState       = BeamState(pas.beamState);
        configurator    = Configurator(pas.configurator);
        timelock        = Timelock(payable(pas.timelock));
        timelockWrapper = TimelockWrapper(pas.timelockWrapper);

        // Initialize using PASInit (must be called by owner who has auth on BeamState and Timelock)
        address[] memory cancellers = new address[](1);
        cancellers[0] = canceller;

        address[] memory pausers = new address[](1);
        pausers[0] = pauser;

        vm.startPrank(owner);
        PASInit.init(pas, MIN_DELAY, coreCouncil, cancellers, pausers);
        vm.stopPrank();
    }

    // ============================================================================
    // Deployment and Initialization Tests
    // ============================================================================

    function testDeploymentAddresses() public view {
        assertTrue(pas.beamState != address(0), "beamState should be deployed");
        assertTrue(pas.configurator != address(0), "configurator should be deployed");
        assertTrue(pas.timelock != address(0), "timelock should be deployed");
        assertTrue(pas.timelockWrapper != address(0), "timelockWrapper should be deployed");
    }

    function testConfiguratorLinkedToBeamState() public view {
        assertEq(address(configurator.beamState()), address(beamState), "configurator should reference beamState");
    }

    function testTimelockWrapperLinkedCorrectly() public view {
        assertEq(address(timelockWrapper.timelock()), address(timelock), "wrapper should reference timelock");
        assertEq(address(timelockWrapper.beamState()), address(beamState), "wrapper should reference beamState");
    }

    function testTimelockRolesAfterInit() public view {
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), owner), "owner should be admin");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), coreCouncil), "coreCouncil should be proposer");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(timelockWrapper)), "wrapper should be proposer");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), coreCouncil), "coreCouncil should be canceller");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), canceller), "canceller should have role");
        assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), pauser), "pauser should have role");
    }

    function testBeamStateRolesAfterInit() public view {
        // Timelock has role 1
        assertTrue(beamState.hasUserRole(address(timelock), 1), "timelock should have role 1");
        // CoreCouncil has role 2
        assertTrue(beamState.hasUserRole(coreCouncil, 2), "coreCouncil should have role 2");
    }

    function testBeamStateActionsConfigured() public view {
        // Role 1 actions (timelocked)
        assertTrue(beamState.isActionInRole(BeamState.start.selector, 1), "start should be role 1");
        assertTrue(beamState.isActionInRole(BeamState.setHop.selector, 1), "setHop should be role 1");
        assertTrue(beamState.isActionInRole(BeamState.setMaxChange.selector, 1), "setMaxChange should be role 1");
        assertTrue(beamState.isActionInRole(BeamState.addRateLimits.selector, 1), "addRateLimits should be role 1");
        assertTrue(beamState.isActionInRole(BeamState.addController.selector, 1), "addController should be role 1");
        assertTrue(beamState.isActionInRole(BeamState.addCBeam.selector, 1), "addCBeam should be role 1");
        assertTrue(beamState.isActionInRole(BeamState.addInitRateLimits.selector, 1), "addInitRateLimits should be role 1");
        assertTrue(beamState.isActionInRole(BeamState.addInitControllerActions.selector, 1), "addInitControllerActions should be role 1");

        // Role 2 actions (direct)
        assertTrue(beamState.isActionInRole(BeamState.stop.selector, 2), "stop should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.delRateLimits.selector, 2), "delRateLimits should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.delController.selector, 2), "delController should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.delCBeam.selector, 2), "delCBeam should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.setCBeamForRateLimits.selector, 2), "setCBeamForRateLimits should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.unsetCBeamForRateLimits.selector, 2), "unsetCBeamForRateLimits should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.setCBeamForController.selector, 2), "setCBeamForController should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.unsetCBeamForController.selector, 2), "unsetCBeamForController should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.delInitRateLimits.selector, 2), "delInitRateLimits should be role 2");
        assertTrue(beamState.isActionInRole(BeamState.delInitControllerActions.selector, 2), "delInitControllerActions should be role 2");
    }

    function testTimelockWrapperBudsAfterInit() public view {
        assertEq(timelockWrapper.buds(coreCouncil), 1, "coreCouncil should be whitelisted on wrapper");
    }

    // ============================================================================
    // CoreCouncil Direct Actions (Role 2) Tests
    // ============================================================================

    function testCoreCouncilCanStop() public {
        assertFalse(beamState.stopped(), "should not be stopped initially");

        vm.prank(coreCouncil);
        beamState.stop();

        assertTrue(beamState.stopped(), "should be stopped after coreCouncil calls stop");
    }

    function testCoreCouncilCanDelRateLimits() public {
        // Setup: owner adds rateLimits
        vm.prank(owner);
        beamState.addRateLimits(SPARK_RATE_LIMITS);
        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 1, "rateLimits should be added");

        // CoreCouncil can delete (role 2)
        vm.prank(coreCouncil);
        beamState.delRateLimits(SPARK_RATE_LIMITS);

        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 0, "rateLimits should be deleted");
    }

    function testCoreCouncilCanDelController() public {
        // Setup: owner adds controller
        vm.prank(owner);
        beamState.addController(SPARK_CONTROLLER);
        assertEq(beamState.controllers(SPARK_CONTROLLER), 1, "controller should be added");

        // CoreCouncil can delete (role 2)
        vm.prank(coreCouncil);
        beamState.delController(SPARK_CONTROLLER);

        assertEq(beamState.controllers(SPARK_CONTROLLER), 0, "controller should be deleted");
    }

    function testCoreCouncilCanDelCBeam() public {
        // Owner adds cBeam directly (has auth/wards)
        vm.prank(owner);
        beamState.addCBeam(cBeam);
        assertEq(beamState.cBeams(cBeam), 1, "cBeam should be added");

        // CoreCouncil can delete (role 2 action)
        vm.prank(coreCouncil);
        beamState.delCBeam(cBeam);
        assertEq(beamState.cBeams(cBeam), 0, "cBeam should be deleted");
    }

    function testCoreCouncilCanSetAndUnsetCBeamForRateLimits() public {
        // Setup: owner adds rateLimits and cBeam, then sets association
        vm.startPrank(owner);
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
        // Setup: owner adds controller and cBeam, then sets association
        vm.startPrank(owner);
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

        // Setup: owner adds init rate limits
        vm.prank(owner);
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

        // Setup: owner adds init controller action
        vm.prank(owner);
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
    // Timelock Flow Tests (Role 1 Actions)
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
    // TimelockWrapper Tests
    // ============================================================================

    function testWrapperCanSchedule() public {
        // First stop via coreCouncil
        vm.prank(coreCouncil);
        beamState.stop();
        assertTrue(beamState.stopped(), "should be stopped");

        // Schedule start via wrapper
        vm.prank(coreCouncil);
        bytes32 operationId = timelockWrapper.start(bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        Timelock.Operation memory op = timelock.getOperation(operationId);
        timelock.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);

        assertFalse(beamState.stopped(), "should be started via wrapper");
    }

    // ============================================================================
    // Cancellation Tests
    // ============================================================================

    function testCoreCouncilCanCancelOperation() public {
        // Schedule operation
        vm.prank(coreCouncil);
        bytes32 operationId = timelockWrapper.addCBeam(cBeam, bytes32(0), SALT, MIN_DELAY);

        assertTrue(timelock.isOperationPending(operationId), "operation should be pending");

        // Cancel
        vm.prank(coreCouncil);
        timelock.cancel(operationId);

        assertFalse(timelock.isOperationPending(operationId), "operation should be cancelled");
        assertEq(timelock.getOperationCount(), 0, "operation count should be 0");
    }

    function testCancellerCanCancelOperation() public {
        vm.prank(coreCouncil);
        bytes32 operationId = timelockWrapper.addCBeam(cBeam, bytes32(0), SALT, MIN_DELAY);

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

        vm.prank(coreCouncil);
        vm.expectRevert();
        timelockWrapper.addCBeam(cBeam, bytes32(0), SALT, MIN_DELAY);
    }

    function testPausedTimelockBlocksExecution() public {
        // Schedule first
        vm.prank(coreCouncil);
        bytes32 operationId = timelockWrapper.addCBeam(cBeam, bytes32(0), SALT, MIN_DELAY);

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

        vm.prank(owner);
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
        // 1. CoreCouncil schedules adding a cBeam via wrapper
        vm.prank(coreCouncil);
        bytes32 addCBeamOp = timelockWrapper.addCBeam(cBeam, bytes32(0), keccak256("step1"), MIN_DELAY);

        // 2. Schedule addRateLimits with predecessor
        vm.prank(coreCouncil);
        bytes32 addRateLimitsOp = timelockWrapper.addRateLimits(SPARK_RATE_LIMITS, addCBeamOp, keccak256("step2"), MIN_DELAY);

        // 3. Schedule setHop with predecessor
        vm.prank(coreCouncil);
        bytes32 setHopOp = timelockWrapper.setHop(SPARK_RATE_LIMITS, 4 hours, addRateLimitsOp, keccak256("step3"), MIN_DELAY);

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
        vm.prank(coreCouncil);
        bytes32 startOp = timelockWrapper.start(bytes32(0), keccak256("restart"), MIN_DELAY);

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

        vm.prank(owner);
        timelock.updateDelayImmediately(newDelay);

        assertEq(timelock.getMinDelay(), newDelay, "delay should be updated immediately");
    }

    function testNonAdminCannotChangeDelay() public {
        vm.prank(coreCouncil);
        vm.expectRevert();
        timelock.updateDelayImmediately(2 days);
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
        // Phase 1: Onboard via Timelock (Role 1)
        // ========================================
        bytes32[] memory opIds = new bytes32[](7);
        {
            // 1a. Schedule addCBeam
            vm.prank(coreCouncil);
            opIds[0] = timelockWrapper.addCBeam(cBeam, bytes32(0), keccak256("addCBeam"), MIN_DELAY);

            // 1b. Schedule addRateLimits for SPARK_RATE_LIMITS
            vm.prank(coreCouncil);
            opIds[1] = timelockWrapper.addRateLimits(SPARK_RATE_LIMITS, opIds[0], keccak256("addRateLimits"), MIN_DELAY);

            // 1c. Schedule addController for SPARK_CONTROLLER
            vm.prank(coreCouncil);
            opIds[2] = timelockWrapper.addController(SPARK_CONTROLLER, opIds[1], keccak256("addController"), MIN_DELAY);

            // 1d. Schedule setHop for rateLimits
            vm.prank(coreCouncil);
            opIds[3] = timelockWrapper.setHop(SPARK_RATE_LIMITS, 1 hours, opIds[2], keccak256("setHop"), MIN_DELAY);

            // 1e. Schedule setMaxChange for rateLimits
            vm.prank(coreCouncil);
            opIds[4] = timelockWrapper.setMaxChange(SPARK_RATE_LIMITS, 2 ether, opIds[3], keccak256("setMaxChange"), MIN_DELAY);

            // 1f. Schedule addInitRateLimits (via wrapper with RateLimitConfig)
            vm.prank(coreCouncil);
            opIds[5] = timelockWrapper.addInitRateLimits(
                RateLimitConfig({key: rateLimitKey, rateLimits: SPARK_RATE_LIMITS, maxAmount: 1_000_000e18, slope: 100_000e18}),
                opIds[4], keccak256("addInitRateLimits"), MIN_DELAY
            );

            // 1g. Schedule addInitControllerActions (directly via timelock - no wrapper for generic actions)
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
            uint32(7),  // different domain
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
        vm.prank(coreCouncil);
        bytes32 startOp = timelockWrapper.start(bytes32(0), keccak256("restart"), MIN_DELAY);

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
