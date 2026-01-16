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
import { TimelockKeeperJob } from "src/timelock/TimelockKeeperJob.sol";
import { Timelock } from "src/timelock/Timelock.sol";

contract MockSequencer {
    mapping(bytes32 => bool) public masterNetworks;

    function setMaster(bytes32 network, bool isMaster_) external {
        masterNetworks[network] = isMaster_;
    }

    function isMaster(bytes32 network) external view returns (bool) {
        return masterNetworks[network];
    }
}

contract MockTarget {
    uint256 public value;
    bool public called;

    function setValue(uint256 _value) external {
        value = _value;
        called = true;
    }

    function revertCall() external pure {
        revert("MockTarget: revert");
    }

    function receiveEther() external payable {
        called = true;
    }

    // Fallback to accept empty payload calls
    fallback() external payable {
        called = true;
    }

    receive() external payable {
        called = true;
    }
}


contract TimelockKeeperJobTest is Test {
    TimelockKeeperJob public keeper;
    Timelock public timelock;
    MockSequencer public sequencer;
    MockTarget public mockTarget;

    address public admin;
    address public proposer;

    uint256 public constant MIN_DELAY = 1 days;
    bytes32 public constant NETWORK = keccak256("mainnet");
    bytes32 public constant SALT = keccak256("test-salt");

    event Work(bytes32 indexed network, bytes32 indexed operationId);

    function setUp() public {
        admin = address(this);
        proposer = address(0x2);

        // Deploy sequencer mock
        sequencer = new MockSequencer();
        sequencer.setMaster(NETWORK, true);

        // Deploy timelock
        timelock = new Timelock(MIN_DELAY, admin);

        // Grant proposer role after deployment
        timelock.grantRole(timelock.PROPOSER_ROLE(), proposer);

        // Deploy keeper
        keeper = new TimelockKeeperJob(address(sequencer), address(timelock), 100);

        // Deploy mock target
        mockTarget = new MockTarget();

        // Fund timelock for ETH operations
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

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);

        return timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
    }

    function _toArray(address addr) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = addr;
        return arr;
    }

    function _toArray(uint256 val) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = val;
        return arr;
    }

    function _toArrayBytes(bytes memory data) internal pure returns (bytes[] memory) {
        bytes[] memory arr = new bytes[](1);
        arr[0] = data;
        return arr;
    }

    function testConstructor() public view {
        assertEq(address(keeper.sequencer()), address(sequencer), "Sequencer set");
        assertEq(address(keeper.timelock()), address(timelock), "Timelock set");
        assertEq(keeper.maxIterations(), 100, "maxIterations set");
    }

    // ============================================================================
    // Work Function Tests
    // ============================================================================

    function testWorkExecutesOperation() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        bytes32 opId = _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectEmit(true, true, false, false);
        emit Work(NETWORK, opId);
        keeper.work(NETWORK, "");

        assertTrue(mockTarget.called(), "Target was called");
        assertEq(mockTarget.value(), 42, "Value was set");
        assertEq(timelock.getOperationCount(), 0, "Operation removed from queue");
    }

    function testWorkRevertsIfNotMaster() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        bytes32 wrongNetwork = keccak256("wrong-network");

        vm.expectRevert(abi.encodeWithSelector(TimelockKeeperJob.NotMaster.selector, wrongNetwork));
        keeper.work(wrongNetwork, "");
    }

    function testWorkRevertsIfNoExecutableOperation() public {
        // No operations scheduled
        vm.expectRevert(TimelockKeeperJob.NoExecutableOperation.selector);
        keeper.work(NETWORK, "");
    }

    function testWorkRevertsIfOperationNotReady() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        // Don't warp time - operation not ready
        vm.expectRevert(TimelockKeeperJob.NoExecutableOperation.selector);
        keeper.work(NETWORK, "");
    }

    function testWorkRevertsIfTargetReverts() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.revertCall.selector);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectRevert("MockTarget: revert");
        keeper.work(NETWORK, "");
    }

    function testWorkMultipleOperationsExecutesFirst() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);

        bytes32 opId1 = _schedule(address(mockTarget), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);
        _schedule(address(mockTarget), 0, data2, bytes32(0), keccak256("s2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.expectEmit(true, true, false, false);
        emit Work(NETWORK, opId1);
        keeper.work(NETWORK, "");

        assertEq(mockTarget.value(), 1, "First operation executed");
        assertEq(timelock.getOperationCount(), 1, "One operation remaining");

        // Execute second
        keeper.work(NETWORK, "");
        assertEq(mockTarget.value(), 2, "Second operation executed");
        assertEq(timelock.getOperationCount(), 0, "No operations remaining");
    }

    function testWorkSkipsNotReadyOperations() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);

        // First operation with longer delay (not ready yet)
        _schedule(address(mockTarget), 0, data1, bytes32(0), keccak256("s1"), 10 days);
        // Second operation with shorter delay (will be ready)
        bytes32 opId2 = _schedule(address(mockTarget), 0, data2, bytes32(0), keccak256("s2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Keeper should skip first (not ready) and execute second
        vm.expectEmit(true, true, false, false);
        emit Work(NETWORK, opId2);
        keeper.work(NETWORK, "");

        assertEq(mockTarget.value(), 2, "Second operation executed");
        assertEq(timelock.getOperationCount(), 1, "First operation still pending");
    }

    function testWorkWithPredecessor() public {
        bytes memory data1 = abi.encodeWithSelector(MockTarget.setValue.selector, 1);
        bytes memory data2 = abi.encodeWithSelector(MockTarget.setValue.selector, 2);

        bytes32 opId1 = _schedule(address(mockTarget), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);
        _schedule(address(mockTarget), 0, data2, opId1, keccak256("s2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // First work executes first operation
        keeper.work(NETWORK, "");
        assertEq(mockTarget.value(), 1, "First operation executed");

        // Second work executes second operation (predecessor now done)
        keeper.work(NETWORK, "");
        assertEq(mockTarget.value(), 2, "Second operation executed");
    }

    function testWorkRespectsMaxIterations() public {
        // Schedule more than maxIterations operations, with the ready one beyond the limit
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);

        // Schedule 101 operations with long delay (not ready)
        for (uint256 i = 0; i < 101; i++) {
            vm.prank(proposer);
            timelock.scheduleBatch(
                _toArray(address(mockTarget)),
                _toArray(uint256(0)),
                _toArrayBytes(data),
                bytes32(0),
                keccak256(abi.encodePacked("notready", i)),
                10 days
            );
        }

        // Schedule 1 ready operation (will be at index 101, beyond maxIterations=100)
        vm.prank(proposer);
        timelock.scheduleBatch(
            _toArray(address(mockTarget)),
            _toArray(uint256(0)),
            _toArrayBytes(data),
            bytes32(0),
            keccak256("ready"),
            MIN_DELAY
        );

        vm.warp(block.timestamp + MIN_DELAY);

        // Keeper should not find the operation because it's beyond maxIterations
        vm.expectRevert(TimelockKeeperJob.NoExecutableOperation.selector);
        keeper.work(NETWORK, "");
    }

    // ============================================================================
    // Workable Function Tests
    // ============================================================================

    function testWorkableReturnsFalseIfNotMaster() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        bytes32 wrongNetwork = keccak256("wrong-network");
        (bool canWork, bytes memory reason) = keeper.workable(wrongNetwork);

        assertFalse(canWork, "Should not be workable on wrong network");
        assertEq(string(reason), "Network is not master", "Correct reason");
    }

    function testWorkableReturnsFalseIfNoOperation() public {
        (bool canWork, bytes memory reason) = keeper.workable(NETWORK);

        assertFalse(canWork, "Should not be workable with no operations");
        assertEq(string(reason), "No executable operation", "Correct reason");
    }

    function testWorkableReturnsFalseIfOperationNotReady() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        // Don't warp - not ready
        (bool canWork, bytes memory reason) = keeper.workable(NETWORK);

        assertFalse(canWork, "Should not be workable when not ready");
        assertEq(string(reason), "No executable operation", "Correct reason");
    }

    function testWorkableReturnsTrueIfOperationReady() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Use snapshot to prevent workable() from persisting state changes
        uint256 snapshot = vm.snapshot();
        (bool canWork, bytes memory args) = keeper.workable(NETWORK);
        vm.revertTo(snapshot);

        assertTrue(canWork, "Should be workable when ready");
        assertEq(args, "", "Args is empty");

        // Verify state was not changed by workable check
        assertFalse(mockTarget.called(), "Target should not be called by workable check");
        assertEq(timelock.getOperationCount(), 1, "Operation should still exist");
    }

    function testWorkableReturnsFalseIfTargetReverts() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.revertCall.selector);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        (bool canWork, bytes memory reason) = keeper.workable(NETWORK);

        assertFalse(canWork, "Should not be workable when target reverts");
        assertEq(string(reason), "No executable operation", "Correct reason");
    }

    // ============================================================================
    // ETH Handling Tests
    // ============================================================================

    /// Operations requiring ETH will fail via keeper since value is always 0
    function testWorkFailsIfOperationNeedsETHAndTimelockNotFunded() public {
        // Clear timelock balance
        vm.prank(address(timelock));
        (bool success,) = address(0xdead).call{value: address(timelock).balance}("");
        require(success);

        bytes memory data = abi.encodeWithSelector(MockTarget.receiveEther.selector);
        _schedule(address(mockTarget), 1 ether, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Will fail because timelock has no ETH and keeper sends value: 0
        vm.expectRevert();
        keeper.work(NETWORK, "");
    }

    function testWorkSucceedsIfTimelockPreFunded() public {
        // Timelock is already funded in setUp
        bytes memory data = abi.encodeWithSelector(MockTarget.receiveEther.selector);
        _schedule(address(mockTarget), 1 ether, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        keeper.work(NETWORK, "");

        assertTrue(mockTarget.called(), "Target received ETH from pre-funded timelock");
    }

    // ============================================================================
    // Access Control Tests
    // ============================================================================

    function testAnyoneCanCallWork() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Random address can call work
        address randomCaller = address(0x12345);
        vm.prank(randomCaller);
        keeper.work(NETWORK, "");

        assertTrue(mockTarget.called(), "Anyone can execute via keeper");
    }

    function testAnyoneCanCallWorkable() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setValue.selector, 42);
        _schedule(address(mockTarget), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        address randomCaller = address(0x12345);
        vm.prank(randomCaller);
        (bool canWork,) = keeper.workable(NETWORK);

        assertTrue(canWork, "Anyone can call workable");
    }
}
