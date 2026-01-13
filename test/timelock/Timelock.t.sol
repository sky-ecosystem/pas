// SPDX-FileCopyrightText: © 2025 Dai Foundation <www.daifoundation.org>
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

import {Test} from "forge-std/Test.sol";
import {Timelock} from "../../src/timelock/Timelock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

// Mock contract for testing timelock operations
contract MockTarget {
    uint256 public value;
    bool public called;
    bytes public lastData;
    uint256 public lastValue;

    function setValue(uint256 _value) external {
        value = _value;
        called = true;
    }

    function setValueWithData(uint256 _value, bytes calldata _data) external {
        value = _value;
        lastData = _data;
        called = true;
    }

    function receiveEther() external payable {
        lastValue = msg.value;
        called = true;
    }

    function revertCall() external pure {
        revert("MockTarget: intentional revert");
    }
}

contract TimelockTest is Test {
    Timelock public timelock;
    MockTarget public mockTarget;

    address public admin;
    address public proposer;
    address public canceller;
    address public pauser;
    address public executor;
    address public other;

    uint256 public constant MIN_DELAY = 1 days;
    bytes32 public constant SALT = keccak256("test-salt");

    // Events for easier testing
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
    event MinDelayChange(uint256 oldDuration, uint256 newDuration);
    event Paused(address account);
    event Unpaused(address account);

    // Helper functions to convert single operations to batch format
    function _schedule(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) internal {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
    }

    function _execute(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt
    ) internal {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        timelock.executeBatch{value: value}(targets, values, payloads, predecessor, salt);
    }

    function setUp() public {
        admin = address(0x1);
        proposer = address(0x2);
        canceller = address(0x3);
        pauser = address(0x4);
        executor = address(0x5);
        other = address(0x6);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory cancellers = new address[](1);
        cancellers[0] = canceller;

        address[] memory pausers = new address[](1);
        pausers[0] = pauser;

        timelock = new Timelock(MIN_DELAY, admin, proposers, cancellers, pausers);
        mockTarget = new MockTarget();
    }

    // ============================================================================
    // Constructor and Initialization Tests
    // ============================================================================

    function testConstructorInitialization() public {
        // Check min delay
        assertEq(timelock.getMinDelay(), MIN_DELAY);

        // Check roles are set correctly
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        // Proposers are automatically given CANCELLER_ROLE by parent constructor
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), canceller));
        assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), pauser));
        // address(0) means anyone can execute
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));

        // Key security feature: contract itself should not have admin role
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function testConstructorRevertsIfAdminIsZero() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory cancellers = new address[](0);
        address[] memory pausers = new address[](0);

        vm.expectRevert("Timelock/admin-zero-address");
        new Timelock(MIN_DELAY, address(0), proposers, cancellers, pausers);
    }

    function testConstructorMultipleProposers() public {
        address[] memory proposers = new address[](2);
        proposers[0] = address(0x10);
        proposers[1] = address(0x11);
        address[] memory cancellers = new address[](0);
        address[] memory pausers = new address[](0);

        Timelock newTimelock = new Timelock(MIN_DELAY, admin, proposers, cancellers, pausers);
        assertTrue(newTimelock.hasRole(newTimelock.PROPOSER_ROLE(), address(0x10)));
        assertTrue(newTimelock.hasRole(newTimelock.PROPOSER_ROLE(), address(0x11)));
    }

    // ============================================================================
    // Scheduling Tests
    // ============================================================================

    function testScheduleReverts() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        vm.prank(proposer);
        vm.expectRevert("Timelock/use-scheduleBatch");
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testScheduleSingleOperation() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        vm.expectEmit(true, true, true, true);
        emit CallScheduled(id, 0, address(mockTarget), 0, data, bytes32(0), MIN_DELAY);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        assertEq(uint256(timelock.getTimestamp(id)), block.timestamp + MIN_DELAY);
    }

    function testScheduleRevertsIfNotProposer() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(other);
        vm.expectRevert();
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testScheduleRevertsIfDelayTooShort() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        vm.expectRevert();
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY - 1);
    }

    function testScheduleRevertsIfPaused() public {
        vm.prank(pauser);
        timelock.pause();

        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        vm.expectRevert();
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testScheduleRevertsOnSelfCall() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        _schedule(address(timelock), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testScheduleWithValue() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.receiveEther.selector);
        bytes32 id = _hashOperation(address(mockTarget), 1 ether, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 1 ether, data, bytes32(0), SALT, MIN_DELAY);

        assertEq(uint256(timelock.getTimestamp(id)), block.timestamp + MIN_DELAY);
    }

    function testScheduleWithPredecessor() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes32 id1 = _hashOperation(address(mockTarget), 0, data1, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data1, bytes32(0), SALT, MIN_DELAY);

        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);
        bytes32 id2 = _hashOperation(address(mockTarget), 0, data2, id1, keccak256("salt2"));

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data2, id1, keccak256("salt2"), MIN_DELAY);

        assertEq(uint256(timelock.getTimestamp(id2)), block.timestamp + MIN_DELAY);
    }

    function testScheduleBatchMultipleOperations() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);
        payloads[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 20);

        bytes32 id = _hashOperationBatch(targets, values, payloads, bytes32(0), SALT);

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);

        assertEq(uint256(timelock.getTimestamp(id)), block.timestamp + MIN_DELAY);
    }

    function testScheduleBatchRevertsOnSelfCall() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(timelock); // Self call

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);
        payloads[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 20);

        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);
    }

    // ============================================================================
    // Execution Tests
    // ============================================================================

    function testExecuteReverts() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        
        vm.expectRevert("Timelock/use-executeBatch");
        timelock.execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testExecuteSingleOperation() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectEmit(true, true, true, true);
        emit CallExecuted(id, 0, address(mockTarget), 0, data);
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);

        assertTrue(mockTarget.called());
        assertEq(mockTarget.value(), 42);
    }

    function testExecutePermissionless() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Anyone can execute
        vm.prank(other);
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);

        assertTrue(mockTarget.called());
    }

    function testExecuteRevertsIfNotReady() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        // Try to execute before delay
        vm.expectRevert();
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testExecuteRevertsIfPaused() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(pauser);
        timelock.pause();

        vm.expectRevert();
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testExecuteWithValue() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.receiveEther.selector);
        bytes32 id = _hashOperation(address(mockTarget), 1 ether, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 1 ether, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.deal(address(timelock), 1 ether);
        _execute(address(mockTarget), 1 ether, data, bytes32(0), SALT);

        assertTrue(mockTarget.called());
        assertEq(mockTarget.lastValue(), 1 ether);
    }

    function testExecuteRevertsIfTargetReverts() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.revertCall.selector);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert("MockTarget: intentional revert");
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testExecuteWithPredecessor() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes32 id1 = _hashOperation(address(mockTarget), 0, data1, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data1, bytes32(0), SALT, MIN_DELAY);

        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);
        bytes32 id2 = _hashOperation(address(mockTarget), 0, data2, id1, keccak256("salt2"));

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data2, id1, keccak256("salt2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Execute first operation
        _execute(address(mockTarget), 0, data1, bytes32(0), SALT);
        assertEq(mockTarget.value(), 1);

        // Execute second operation (requires predecessor to be done)
        _execute(address(mockTarget), 0, data2, id1, keccak256("salt2"));
        assertEq(mockTarget.value(), 2);
    }

    function testExecuteRevertsIfPredecessorNotDone() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes32 id1 = _hashOperation(address(mockTarget), 0, data1, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data1, bytes32(0), SALT, MIN_DELAY);

        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);
        bytes32 id2 = _hashOperation(address(mockTarget), 0, data2, id1, keccak256("salt2"));

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data2, id1, keccak256("salt2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Try to execute second operation before first
        vm.expectRevert();
        _execute(address(mockTarget), 0, data2, id1, keccak256("salt2"));
    }

    function testExecuteBatchMultipleOperations() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);
        payloads[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 20);

        bytes32 id = _hashOperationBatch(targets, values, payloads, bytes32(0), SALT);

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);

        // Last operation sets value to 20
        assertEq(mockTarget.value(), 20);
    }

    // ============================================================================
    // Cancellation Tests
    // ============================================================================

    function testCancelProposerCanCancel() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(proposer);
        vm.expectEmit(true, false, false, false);
        emit Cancelled(id);
        timelock.cancel(id);

        assertEq(uint256(timelock.getTimestamp(id)), 0);
    }

    function testCancelCancellerCanCancel() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(canceller);
        timelock.cancel(id);

        assertEq(uint256(timelock.getTimestamp(id)), 0);
    }

    function testCancelRevertsIfNotAuthorized() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(other);
        vm.expectRevert();
        timelock.cancel(id);
    }

    function testCancelCannotCancelAfterExecution() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        vm.expectRevert();
        timelock.cancel(id);
    }

    // ============================================================================
    // Pausing Tests
    // ============================================================================

    function testPausePauserCanPause() public {
        vm.prank(pauser);
        vm.expectEmit(true, false, false, false);
        emit Paused(pauser);
        timelock.pause();

        assertTrue(timelock.paused());
    }

    function testPauseRevertsIfNotPauser() public {
        vm.prank(other);
        vm.expectRevert();
        timelock.pause();
    }

    function testUnpauseAdminCanUnpause() public {
        vm.prank(pauser);
        timelock.pause();

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit Unpaused(admin);
        timelock.unpause();

        assertFalse(timelock.paused());
    }

    function testUnpauseRevertsIfNotAdmin() public {
        vm.prank(pauser);
        timelock.pause();

        vm.prank(other);
        vm.expectRevert();
        timelock.unpause();
    }

    function testPauseBlocksScheduling() public {
        vm.prank(pauser);
        timelock.pause();

        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        vm.expectRevert();
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testPauseBlocksExecution() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(pauser);
        timelock.pause();

        vm.expectRevert();
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testPauseBlocksScheduleBatch() public {
        vm.prank(pauser);
        timelock.pause();

        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);

        vm.prank(proposer);
        vm.expectRevert();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);
    }

    function testPauseBlocksExecuteBatch() public {
        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(pauser);
        timelock.pause();

        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);
    }

    // ============================================================================
    // Delay Management Tests
    // ============================================================================

    function testUpdateDelayImmediatelyAdminCanUpdate() public {
        uint256 newDelay = 2 days;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit MinDelayChange(MIN_DELAY, newDelay);
        timelock.updateDelayImmediately(newDelay);

        assertEq(timelock.getMinDelay(), newDelay);
    }

    function testUpdateDelayImmediatelyRevertsIfNotAdmin() public {
        vm.prank(other);
        vm.expectRevert();
        timelock.updateDelayImmediately(2 days);
    }

    function testUpdateDelayImmediatelyProposerCannotChangeDelay() public {
        bytes memory data = abi.encodeWithSelector(
            Timelock.updateDelayImmediately.selector,
            2 days
        );

        // Try to schedule a call to updateDelayImmediately
        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        _schedule(address(timelock), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testUpdateDelayImmediatelyNewDelayAppliesToFutureOperations() public {
        uint256 newDelay = 2 days;

        vm.prank(admin);
        timelock.updateDelayImmediately(newDelay);

        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        // Old delay should fail
        vm.expectRevert();
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        // New delay should work
        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, newDelay);
    }

    // ============================================================================
    // Security Tests - Self Call Prevention
    // ============================================================================

    function testSelfCallPreventionSchedule() public {
        bytes memory data = abi.encodeWithSelector(
            TimelockController.updateDelay.selector,
            2 days
        );

        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        _schedule(address(timelock), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testSelfCallPreventionScheduleBatch() public {
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(
            TimelockController.updateDelay.selector,
            2 days
        );

        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);
    }

    function testSelfCallPreventionCannotGrantAdminRole() public {
        bytes memory data = abi.encodeWithSelector(
            AccessControl.grantRole.selector,
            timelock.DEFAULT_ADMIN_ROLE(),
            proposer
        );

        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        _schedule(address(timelock), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    // ============================================================================
    // Edge Cases and Integration Tests
    // ============================================================================

    function testOperationStateUnsetToWaitingToReady() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        // Initially unset
        assertEq(uint256(timelock.getTimestamp(id)), 0);

        // Schedule - now waiting
        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
        assertGt(uint256(timelock.getTimestamp(id)), 0);

        // After delay - ready
        vm.warp(block.timestamp + MIN_DELAY);
        assertTrue(timelock.isOperationReady(id));

        // Execute - done
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
        assertTrue(timelock.isOperationDone(id));
    }

    function testMultipleOperationsSameTarget() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes32 id1 = _hashOperation(address(mockTarget), 0, data1, bytes32(0), SALT);

        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);
        bytes32 id2 = _hashOperation(address(mockTarget), 0, data2, bytes32(0), keccak256("salt2"));

        vm.startPrank(proposer);
        _schedule(address(mockTarget), 0, data1, bytes32(0), SALT, MIN_DELAY);
        _schedule(address(mockTarget), 0, data2, bytes32(0), keccak256("salt2"), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        _execute(address(mockTarget), 0, data1, bytes32(0), SALT);
        assertEq(mockTarget.value(), 1);

        _execute(address(mockTarget), 0, data2, bytes32(0), keccak256("salt2"));
        assertEq(mockTarget.value(), 2);
    }

    function testFullWorkflowScheduleExecuteCancel() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        // Schedule
        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
        assertGt(uint256(timelock.getTimestamp(id)), 0);

        // Cancel
        vm.prank(canceller);
        timelock.cancel(id);
        assertEq(uint256(timelock.getTimestamp(id)), 0);

        // Try to execute (should fail)
        vm.warp(block.timestamp + MIN_DELAY);
        vm.expectRevert();
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testPauseUnpauseResumeOperations() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        // Schedule
        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        // Pause
        vm.prank(pauser);
        timelock.pause();

        // Unpause
        vm.prank(admin);
        timelock.unpause();

        // Execute should work now
        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
        assertTrue(mockTarget.called());
    }

    // ============================================================================
    // Helper Functions
    // ============================================================================

    function _hashOperation(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt
    ) internal view returns (bytes32) {
        // Convert to batch format for hashing
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        return timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
    }

    function _hashOperationBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 predecessor,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(targets, values, payloads, predecessor, salt));
    }
}

