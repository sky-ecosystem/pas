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

import { Test } from "forge-std/Test.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MockTarget {
    uint256 public value;
    bool public called;
    uint256 public callCount;
    uint256 public lastEthReceived;

    function setValue(uint256 _value) external {
        value = _value;
        called = true;
        callCount++;
    }

    function receiveEther() external payable {
        lastEthReceived = msg.value;
        called = true;
        callCount++;
    }

    function revertCall() external pure {
        revert("MockTarget: intentional revert");
    }
}

contract TimelockTest is Test {
    Timelock   public timelock;
    MockTarget public mockTarget;
    MockTarget public mockTarget2;

    address public admin;
    address public proposer;
    address public proposer2;
    address public canceller;
    address public pauser;
    address public other;

    uint256 public constant MIN_DELAY = 1 days;
    bytes32 public constant SALT = keccak256("test-salt");

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

    function setUp() public {
        admin     = address(0x1);
        proposer  = address(0x2);
        proposer2 = address(0x22);
        canceller = address(0x3);
        pauser    = address(0x4);
        other     = address(0x5);

        timelock    = new Timelock(MIN_DELAY, admin);
        mockTarget  = new MockTarget();
        mockTarget2 = new MockTarget();

        // Grant roles after deployment
        vm.startPrank(admin);
        timelock.grantRole(timelock.PROPOSER_ROLE(), proposer);
        timelock.grantRole(timelock.PROPOSER_ROLE(), proposer2);
        // Proposers also get canceller role (matches original TimelockController behavior)
        timelock.grantRole(timelock.CANCELLER_ROLE(), proposer);
        timelock.grantRole(timelock.CANCELLER_ROLE(), proposer2);
        timelock.grantRole(timelock.CANCELLER_ROLE(), canceller);
        timelock.grantRole(timelock.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        vm.deal(address(timelock), 100 ether);
    }

    // ============================================================================
    // Helper Functions
    // ============================================================================

    function _schedule(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) internal returns (bytes32) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        return timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
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

    function _hashOperation(
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt
    ) internal view returns (bytes32) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        return timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
    }

    // ============================================================================
    // Constructor and Initialization Tests
    // ============================================================================

    function testConstructorInitialization() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY);
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer2));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer2));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), canceller));
        assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), pauser));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function testConstructorRevertsIfAdminIsZero() public {
        vm.expectRevert("Timelock/admin-zero-address");
        new Timelock(MIN_DELAY, address(0));
    }

    // ============================================================================
    // Role Management Tests
    // ============================================================================

    function testAdminCanGrantRole() public {
        address newProposer = address(0x999);
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        assertFalse(timelock.hasRole(proposerRole, newProposer));

        vm.prank(admin);
        timelock.grantRole(proposerRole, newProposer);

        assertTrue(timelock.hasRole(proposerRole, newProposer));

        // Verify the new proposer can actually schedule
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        vm.prank(newProposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        assertEq(timelock.getOperationCount(), 1);
    }

    function testAdminCanRevokeRole() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        assertTrue(timelock.hasRole(proposerRole, proposer));

        vm.prank(admin);
        timelock.revokeRole(proposerRole, proposer);

        assertFalse(timelock.hasRole(proposerRole, proposer));

        // Verify the revoked proposer can no longer schedule
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, proposer, proposerRole));
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testNonAdminCannotGrantRole() public {
        address newProposer = address(0x999);
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole));
        timelock.grantRole(proposerRole, newProposer);
    }

    function testNonAdminCannotRevokeRole() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole));
        timelock.revokeRole(proposerRole, proposer);
    }

    function testUserCanRenounceOwnRole() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        assertTrue(timelock.hasRole(proposerRole, proposer));

        vm.prank(proposer);
        timelock.renounceRole(proposerRole, proposer);

        assertFalse(timelock.hasRole(proposerRole, proposer));

        // Verify the user can no longer schedule
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, proposer, proposerRole));
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testUserCannotRenounceOthersRole() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlBadConfirmation.selector));
        timelock.renounceRole(proposerRole, proposer);

        // Proposer still has their role
        assertTrue(timelock.hasRole(proposerRole, proposer));
    }

    function testAdminRoleTransfer() public {
        address newAdmin = address(0x888);
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        // Admin grants admin role to new address
        vm.prank(admin);
        timelock.grantRole(adminRole, newAdmin);

        assertTrue(timelock.hasRole(adminRole, newAdmin));

        // New admin can grant roles
        address newProposer = address(0x999);
        vm.prank(newAdmin);
        timelock.grantRole(proposerRole, newProposer);

        assertTrue(timelock.hasRole(proposerRole, newProposer));

        // Old admin renounces
        vm.prank(admin);
        timelock.renounceRole(adminRole, admin);

        assertFalse(timelock.hasRole(adminRole, admin));

        // Old admin can no longer grant roles
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole));
        timelock.grantRole(proposerRole, address(0x777));
    }

    // ============================================================================
    // Scheduling Tests
    // ============================================================================

    function testScheduleSingleReverts() public {
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
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, proposerRole));
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testScheduleRevertsIfDelayTooShort() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, MIN_DELAY - 1, MIN_DELAY));
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY - 1);
    }

    function testScheduleRevertsIfPaused() public {
        vm.prank(pauser);
        timelock.pause();

        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testScheduleRevertsOnSelfCall() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        _schedule(address(timelock), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    function testScheduleBatchRevertsOnSelfCall() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(timelock);

        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);
        payloads[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 20);

        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);
    }

    function testCannotScheduleDuplicate() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.startPrank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(1 << uint8(TimelockController.OperationState.Unset))));
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);
        vm.stopPrank();
    }

    function testDifferentSaltCreatesDifferentId() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.startPrank(proposer);
        bytes32 id1 = _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s1"), MIN_DELAY);
        bytes32 id2 = _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s2"), MIN_DELAY);
        vm.stopPrank();

        assertTrue(id1 != id2);
        assertEq(timelock.getOperationCount(), 2);
    }

    function testMultipleProposersCanSchedule() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);

        vm.prank(proposer2);
        _schedule(address(mockTarget), 0, data2, bytes32(0), keccak256("s2"), MIN_DELAY);

        assertEq(timelock.getOperationCount(), 2);
    }

    // ============================================================================
    // Execution Tests
    // ============================================================================

    function testExecuteSingleReverts() public {
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

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(other);
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);

        assertTrue(mockTarget.called());
    }

    function testExecuteRevertsIfNotReady() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 id = _hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(1 << uint8(TimelockController.OperationState.Ready))));
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testExecuteRevertsIfPaused() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(pauser);
        timelock.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testExecuteRevertsIfTargetReverts() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.revertCall.selector);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert("MockTarget: intentional revert");
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function testExecuteBatchMultipleOperations() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 10);
        payloads[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 20);

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);

        assertEq(mockTarget.value(), 20);
    }

    function testLargeBatch() public {
        uint256 batchSize = 50;

        address[] memory targets = new address[](batchSize);
        uint256[] memory values = new uint256[](batchSize);
        bytes[] memory payloads = new bytes[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            targets[i] = address(mockTarget);
            payloads[i] = abi.encodeWithSelector(MockTarget.setValue.selector, i);
        }

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);

        assertEq(mockTarget.value(), batchSize - 1);
        assertEq(mockTarget.callCount(), batchSize);
    }

    // ============================================================================
    // Predecessor Chain Tests
    // ============================================================================

    function testExecuteWithPredecessor() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes32 id1 = _hashOperation(address(mockTarget), 0, data1, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data1, bytes32(0), SALT, MIN_DELAY);

        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data2, id1, keccak256("salt2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        _execute(address(mockTarget), 0, data1, bytes32(0), SALT);
        assertEq(mockTarget.value(), 1);

        _execute(address(mockTarget), 0, data2, id1, keccak256("salt2"));
        assertEq(mockTarget.value(), 2);
    }

    function testExecuteRevertsIfPredecessorNotDone() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes32 id1 = _hashOperation(address(mockTarget), 0, data1, bytes32(0), SALT);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data1, bytes32(0), SALT, MIN_DELAY);

        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data2, id1, keccak256("salt2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, id1));
        _execute(address(mockTarget), 0, data2, id1, keccak256("salt2"));
    }

    function testCancelledPredecessorBlocksDependent() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);

        vm.startPrank(proposer);
        bytes32 id1 = _schedule(address(mockTarget), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);
        _schedule(address(mockTarget), 0, data2, id1, keccak256("s2"), MIN_DELAY);
        vm.stopPrank();

        vm.prank(canceller);
        timelock.cancel(id1);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, id1));
        _execute(address(mockTarget), 0, data2, id1, keccak256("s2"));
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

        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, cancellerRole));
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
        // Cancel expects operation to be Waiting OR Ready
        bytes32 expectedStates = bytes32((1 << uint8(TimelockController.OperationState.Waiting)) | (1 << uint8(TimelockController.OperationState.Ready)));
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, expectedStates));
        timelock.cancel(id);
    }

    function testCancelRevertsWhilePaused() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        bytes32 id = _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(pauser);
        timelock.pause();

        vm.prank(canceller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        timelock.cancel(id);
    }

    function testCancelWorksAfterUnpause() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        bytes32 id = _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(pauser);
        timelock.pause();

        vm.prank(admin);
        timelock.unpause();

        vm.prank(canceller);
        timelock.cancel(id);

        assertEq(timelock.getOperationCount(), 0);
    }

    function testProposerCanCancelOtherProposersOperation() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        bytes32 id = _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(proposer2);
        timelock.cancel(id);

        assertEq(timelock.getOperationCount(), 0);
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
        bytes32 pauserRole = timelock.PAUSER_ROLE();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, pauserRole));
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

        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole));
        timelock.unpause();
    }

    function testPauserCannotUnpause() public {
        vm.prank(pauser);
        timelock.pause();

        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole));
        timelock.unpause();

        vm.prank(admin);
        timelock.unpause();
        assertFalse(timelock.paused());
    }

    function testPauseUnpauseResumesOperations() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(pauser);
        timelock.pause();

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(admin);
        timelock.unpause();

        _execute(address(mockTarget), 0, data, bytes32(0), SALT);
        assertTrue(mockTarget.called());
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
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole));
        timelock.updateDelayImmediately(2 days);
    }

    function testNewDelayAppliesImmediately() public {
        vm.prank(admin);
        timelock.updateDelayImmediately(2 days);

        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, MIN_DELAY, 2 days));
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, 2 days);
        assertEq(timelock.getOperationCount(), 1);
    }

    function testUpdateDelayImmediatelyProposerCannotChangeDelay() public {
        bytes memory data = abi.encodeWithSelector(Timelock.updateDelayImmediately.selector, 2 days);

        vm.prank(proposer);
        vm.expectRevert("Timelock/self-calls-disabled");
        _schedule(address(timelock), 0, data, bytes32(0), SALT, MIN_DELAY);
    }

    // ============================================================================
    // ETH Handling Tests
    // ============================================================================

    function testExecuteWithETHFromTimelockBalance() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.receiveEther.selector);

        vm.prank(proposer);
        _schedule(address(mockTarget), 1 ether, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        uint256 balanceBefore = address(timelock).balance;

        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);

        assertEq(mockTarget.lastEthReceived(), 1 ether);
        assertEq(address(timelock).balance, balanceBefore - 1 ether);
    }

    function testExecuteWithMsgValue() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.receiveEther.selector);

        vm.prank(proposer);
        _schedule(address(mockTarget), 1 ether, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(address(timelock));
        (bool success,) = other.call{value: address(timelock).balance}("");
        require(success);
        assertEq(address(timelock).balance, 0);

        vm.deal(other, 1 ether);
        vm.prank(other);
        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        timelock.executeBatch{value: 1 ether}(targets, values, payloads, bytes32(0), SALT);

        assertEq(mockTarget.lastEthReceived(), 1 ether);
    }

    function testExecuteMultipleTargetsWithETH() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget2);

        uint256[] memory values = new uint256[](2);
        values[0] = 1 ether;
        values[1] = 2 ether;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSelector(MockTarget.receiveEther.selector);
        payloads[1] = abi.encodeWithSelector(MockTarget.receiveEther.selector);

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);

        assertEq(mockTarget.lastEthReceived(), 1 ether);
        assertEq(mockTarget2.lastEthReceived(), 2 ether);
    }

    // ============================================================================
    // Keeper Helper Function Tests
    // ============================================================================

    function testGetNextExecutableOperationEmpty() public view {
        bytes32 id = timelock.getNextExecutableOperation();
        assertEq(id, bytes32(0));
    }

    function testGetNextExecutableOperationNotReady() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        bytes32 id = timelock.getNextExecutableOperation();
        assertEq(id, bytes32(0));
    }

    function testGetNextExecutableOperationReady() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        bytes32 expectedId = _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        bytes32 id = timelock.getNextExecutableOperation();
        assertEq(id, expectedId);
    }

    function testGetNextExecutableOperationMultipleReturnsFirst() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);
        bytes memory data3 = abi.encodeWithSelector(MockTarget.setValue.selector, 3);

        vm.startPrank(proposer);
        bytes32 id1 = _schedule(address(mockTarget), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);

        vm.warp(block.timestamp + 1 hours);
        _schedule(address(mockTarget), 0, data2, bytes32(0), keccak256("s2"), MIN_DELAY);

        vm.warp(block.timestamp + 1 hours);
        _schedule(address(mockTarget), 0, data3, bytes32(0), keccak256("s3"), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        bytes32 nextId = timelock.getNextExecutableOperation();
        assertEq(nextId, id1);
    }

    function testGetNextExecutableOperationSkipsPendingPredecessor() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);

        vm.startPrank(proposer);
        bytes32 id1 = _schedule(address(mockTarget), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);
        _schedule(address(mockTarget), 0, data2, id1, keccak256("s2"), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        bytes32 nextId = timelock.getNextExecutableOperation();
        assertEq(nextId, id1);

        _execute(address(mockTarget), 0, data1, bytes32(0), keccak256("s1"));

        nextId = timelock.getNextExecutableOperation();
        bytes32 id2 = _hashOperation(address(mockTarget), 0, data2, id1, keccak256("s2"));
        assertEq(nextId, id2);
    }

    function testGetNextExecutableOperationWithMaxIterations() public {
        // Schedule 5 operations, only the 4th one is ready
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.startPrank(proposer);
        // Schedule 3 operations with long delay (not ready)
        _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s1"), 10 days);
        _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s2"), 10 days);
        _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s3"), 10 days);
        // Schedule 1 operation with short delay (will be ready)
        bytes32 readyId = _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s4"), MIN_DELAY);
        // Schedule 1 more with long delay
        _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s5"), 10 days);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        // With maxIterations=3, should not find the ready operation (it's at index 3)
        bytes32 id = timelock.getNextExecutableOperation(3);
        assertEq(id, bytes32(0), "Should not find with limit 3");

        // With maxIterations=4, should find it
        id = timelock.getNextExecutableOperation(4);
        assertEq(id, readyId, "Should find with limit 4");

        // With maxIterations=100, should also find it
        id = timelock.getNextExecutableOperation(100);
        assertEq(id, readyId, "Should find with limit 100");
    }

    function testGetNextExecutableOperationZeroMeansNoLimit() public {
        // Schedule many operations, put the ready one at the end
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.startPrank(proposer);
        // Schedule 10 operations with long delay
        for (uint256 i = 0; i < 10; i++) {
            _schedule(address(mockTarget), 0, data, bytes32(0), keccak256(abi.encodePacked("long", i)), 10 days);
        }
        // Schedule 1 ready operation at the end
        bytes32 readyId = _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("ready"), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        // With maxIterations=0 (no limit), should find it even though it's at index 10
        bytes32 id = timelock.getNextExecutableOperation(0);
        assertEq(id, readyId, "Zero should mean no limit");

        // The no-param version should also work (it calls with 0)
        id = timelock.getNextExecutableOperation();
        assertEq(id, readyId, "No-param version should also find it");
    }

    function testGetOperationNonExistent() public view {
        Timelock.Operation memory op = timelock.getOperation(keccak256("fake"));
        assertEq(op.targets.length, 0);
        assertEq(op.values.length, 0);
        assertEq(op.payloads.length, 0);
    }

    function testGetOperationAfterExecution() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        bytes32 id = _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        Timelock.Operation memory opBefore = timelock.getOperation(id);
        assertEq(opBefore.targets.length, 1);

        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(mockTarget), 0, data, bytes32(0), SALT);

        Timelock.Operation memory opAfter = timelock.getOperation(id);
        assertEq(opAfter.targets.length, 0);
    }

    function testGetOperationAfterCancel() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.prank(proposer);
        bytes32 id = _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.prank(canceller);
        timelock.cancel(id);

        Timelock.Operation memory op = timelock.getOperation(id);
        assertEq(op.targets.length, 0);
    }

    function testOperationCountTracking() public {
        assertEq(timelock.getOperationCount(), 0);

        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        vm.startPrank(proposer);
        bytes32 id1 = _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s1"), MIN_DELAY);
        assertEq(timelock.getOperationCount(), 1);

        _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s2"), MIN_DELAY);
        assertEq(timelock.getOperationCount(), 2);

        _schedule(address(mockTarget), 0, data, bytes32(0), keccak256("s3"), MIN_DELAY);
        assertEq(timelock.getOperationCount(), 3);
        vm.stopPrank();

        vm.prank(canceller);
        timelock.cancel(id1);
        assertEq(timelock.getOperationCount(), 2);

        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(mockTarget), 0, data, bytes32(0), keccak256("s2"));
        assertEq(timelock.getOperationCount(), 1);
    }

    function testOperationDataIntegrity() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget2);

        uint256[] memory values = new uint256[](2);
        values[0] = 1 ether;
        values[1] = 2 ether;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSelector(MockTarget.setValue.selector, 100);
        payloads[1] = abi.encodeWithSelector(MockTarget.setValue.selector, 200);

        bytes32 predecessor = keccak256("pred");
        bytes32 salt = keccak256("salt");

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, MIN_DELAY);

        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
        Timelock.Operation memory op = timelock.getOperation(id);

        assertEq(op.targets.length, 2);
        assertEq(op.targets[0], address(mockTarget));
        assertEq(op.targets[1], address(mockTarget2));
        assertEq(op.values[0], 1 ether);
        assertEq(op.values[1], 2 ether);
        assertEq(op.payloads[0], payloads[0]);
        assertEq(op.payloads[1], payloads[1]);
        assertEq(op.predecessor, predecessor);
        assertEq(op.salt, salt);
    }
}
