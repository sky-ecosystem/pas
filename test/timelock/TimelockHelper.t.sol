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

import { Test } from "forge-std/Test.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { TimelockHelper } from "src/timelock/helpers/TimelockHelper.sol";

contract TimelockHelperTest is Test {
    Timelock       public timelock;
    TimelockHelper public timelockHelper;

    uint256 public constant MIN_DELAY = 1 days;
    bytes32 public constant SALT = keccak256("test-salt");

    function setUp() public {
        timelock       = new Timelock(MIN_DELAY, address(this));
        timelockHelper = new TimelockHelper(address(timelock));

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(this));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(this));
    }

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

    function testGetNextExecutableOperationEmpty() public view {
        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, bytes32(0));
        assertFalse(found);
    }

    function testGetNextExecutableOperationNotReady() public {
        bytes memory data = abi.encodeWithSignature("random(uint256)", 42);

        _schedule(address(123), 0, data, bytes32(0), SALT, MIN_DELAY);

        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, bytes32(0));
        assertFalse(found);
    }

    function testGetNextExecutableOperationReady() public {
        bytes memory data = abi.encodeWithSignature("random(uint256)", 42);

        bytes32 expectedId = _schedule(address(123), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, expectedId);
        assertTrue(found);
    }

    function testGetNextExecutableOperationMultipleReturnsFirst() public {
        bytes memory data1 = abi.encodeWithSignature("random(uint256)", 1);
        bytes memory data2 = abi.encodeWithSignature("random(uint256)", 2);
        bytes memory data3 = abi.encodeWithSignature("random(uint256)", 3);

        bytes32 id1 = _schedule(address(123), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);

        vm.warp(block.timestamp + 1 hours);
        _schedule(address(123), 0, data2, bytes32(0), keccak256("s2"), MIN_DELAY);

        vm.warp(block.timestamp + 1 hours);
        _schedule(address(123), 0, data3, bytes32(0), keccak256("s3"), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, id1);
        assertTrue(found);
    }

    function testGetNextExecutableOperationChangesAfterExecution() public {
        bytes memory data1 = abi.encodeWithSignature("random(uint256)", 1);
        bytes memory data2 = abi.encodeWithSignature("random(uint256)", 2);

        bytes32 id1 = _schedule(address(123), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);
        bytes32 id2 = _schedule(address(123), 0, data2, id1, keccak256("s2"), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, id1);
        assertTrue(found);

        _execute(address(123), 0, data1, bytes32(0), keccak256("s1"));

        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, id2);
        assertTrue(found);
    }

    function testGetNextExecutableOperationWithMaxIterations() public {
        // Schedule 5 operations, only the 4th one is ready
        bytes memory data = abi.encodeWithSignature("random(uint256)", 42);

        // Schedule 3 operations with long delay (not ready)
        _schedule(address(123), 0, data, bytes32(0), keccak256("s1"), 10 days);
        _schedule(address(123), 0, data, bytes32(0), keccak256("s2"), 10 days);
        _schedule(address(123), 0, data, bytes32(0), keccak256("s3"), 10 days);
        // Schedule 1 operation with short delay (will be ready)
        bytes32 expectedReadyId = _schedule(address(123), 0, data, bytes32(0), keccak256("s4"), MIN_DELAY);
        // Schedule 1 more with long delay
        _schedule(address(123), 0, data, bytes32(0), keccak256("s5"), 10 days);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        // With maxIterations=3, should not find the ready operation (it's at position 4)
        // Returns the next id to continue from (s4) with found=false
        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), 3);
        assertEq(id, expectedReadyId, "Should return next id to check with limit 3");
        assertFalse(found, "Should not be found with limit 3");

        // With maxIterations=4, should find it
        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), 4);
        assertEq(id, expectedReadyId, "Should find with limit 4");
        assertTrue(found, "Should be found with limit 4");

        // With maxIterations=100, should also find it
        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), 100);
        assertEq(id, expectedReadyId, "Should find with limit 100");
        assertTrue(found, "Should be found with limit 100");
    }

    function testGetNextExecutableOperationZeroMaxIterationsReverts() public {
        vm.expectRevert("TimelockHelper/zero-maxIterations");
        timelockHelper.getNextExecutableOperationId(bytes32(0), 0);
    }

    function testGetNextExecutableOperationStartWithNonExistentIdReverts() public {
        bytes memory data = abi.encodeWithSignature("random(uint256)", 42);
        _schedule(address(123), 0, data, bytes32(0), SALT, MIN_DELAY);

        // Starting with a non-existent ID reverts
        vm.expectRevert("TimelockHelper/invalid-startId");
        timelockHelper.getNextExecutableOperationId(keccak256("nonexistent"), type(uint256).max);
    }

    function testGetNextExecutableOperationLargeMaxIterations() public {
        bytes memory data = abi.encodeWithSignature("random(uint256)", 42);
        bytes32 expectedId = _schedule(address(123), 0, data, bytes32(0), SALT, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Very large maxIterations should not overflow
        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, expectedId);
        assertTrue(found);
    }

    function testGetNextExecutableOperationPagination() public {
        bytes memory data = abi.encodeWithSignature("random(uint256)", 42);

        _schedule(address(123), 0, data, bytes32(0), keccak256("s0"), 10 days); // not ready
        bytes32 id1 = _schedule(address(123), 0, data, bytes32(0), keccak256("s1"), MIN_DELAY); // ready
        _schedule(address(123), 0, data, bytes32(0), keccak256("s2"), 10 days); // not ready
        bytes32 id3 = _schedule(address(123), 0, data, bytes32(0), keccak256("s3"), MIN_DELAY); // ready
        _schedule(address(123), 0, data, bytes32(0), keccak256("s4"), 10 days); // not ready
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        // First call finds id1
        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, id1);
        assertTrue(found);

        // Continue from after id1 (use getNextOperationId to get next starting point), finds id3
        bytes32 nextStart = timelock.getNextOperationId(id1);
        (found, id) = timelockHelper.getNextExecutableOperationId(nextStart, type(uint256).max);
        assertEq(id, id3);
        assertTrue(found);

        // Continue from after id3, nothing ready left (list exhausted)
        nextStart = timelock.getNextOperationId(id3);
        (found, id) = timelockHelper.getNextExecutableOperationId(nextStart, type(uint256).max);
        assertEq(id, bytes32(0));
        assertFalse(found);
    }

    function testGetNextExecutableOperationSkipsPendingPredecessor() public {
        bytes memory data1 = abi.encodeWithSignature("random(uint256)", 1);
        bytes memory data2 = abi.encodeWithSignature("random(uint256)", 2);
        bytes memory data3 = abi.encodeWithSignature("random(uint256)", 3);

        // Schedule id1 with long delay (won't be ready)
        bytes32 id1 = _schedule(address(123), 0, data1, bytes32(0), keccak256("s1"), 10 days);
        // Schedule id2 with id1 as predecessor (ready but predecessor not done)
        _schedule(address(123), 0, data2, id1, keccak256("s2"), MIN_DELAY);
        // Schedule id3 with no predecessor (ready)
        bytes32 id3 = _schedule(address(123), 0, data3, bytes32(0), keccak256("s3"), MIN_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_DELAY);

        // Should skip id1 (not ready), skip id2 (predecessor not done), return id3
        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, id3);
        assertTrue(found);
    }

    function testGetNextExecutableOperationWithDonePredecessor() public {
        bytes memory data1 = abi.encodeWithSignature("random(uint256)", 1);
        bytes memory data2 = abi.encodeWithSignature("random(uint256)", 2);

        // Schedule operation A (no predecessor)
        bytes32 id1 = _schedule(address(123), 0, data1, bytes32(0), keccak256("s1"), MIN_DELAY);

        // Schedule operation B with A as predecessor
        bytes32 id2 = _schedule(address(123), 0, data2, id1, keccak256("s2"), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Before executing predecessor: should return id1 (id2's predecessor not done)
        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, id1);
        assertTrue(found);

        // Execute id1 (predecessor is now done)
        _execute(address(123), 0, data1, bytes32(0), keccak256("s1"));

        // Now id2's predecessor is done, should return id2
        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, id2);
        assertTrue(found);
    }

    function testGetNextExecutableOperationReturnValues() public {
        bytes memory data = abi.encodeWithSignature("random(uint256)", 42);

        // Case 1: Empty list - id should be bytes32(0), found should be false
        (bool found, bytes32 id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, bytes32(0), "Empty list: id should be 0");
        assertFalse(found, "Empty list: found should be false");

        // Schedule 4 operations with long delays (none ready)
        bytes32 id0 = _schedule(address(123), 0, data, bytes32(0), keccak256("s0"), 10 days);
        bytes32 id1 = _schedule(address(123), 0, data, bytes32(0), keccak256("s1"), 10 days);
        bytes32 id2 = _schedule(address(123), 0, data, bytes32(0), keccak256("s2"), 10 days);
        bytes32 id3 = _schedule(address(123), 0, data, bytes32(0), keccak256("s3"), 10 days);
        vm.stopPrank();

        // Case 2: No operations ready, maxIterations reached - id should be next to check, found false
        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), 2);
        assertEq(id, id2, "Not ready, limit 2: id should be id2 (next to check)");
        assertFalse(found, "Not ready, limit 2: found should be false");

        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), 3);
        assertEq(id, id3, "Not ready, limit 3: id should be id3 (next to check)");
        assertFalse(found, "Not ready, limit 3: found should be false");

        // Case 3: No operations ready, list exhausted - id should be bytes32(0), found false
        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, bytes32(0), "Not ready, exhausted: id should be 0");
        assertFalse(found, "Not ready, exhausted: found should be false");

        // Make operations ready
        vm.warp(block.timestamp + 10 days);

        // Case 4: Ready operation found - id should be the ready operation, found true
        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), type(uint256).max);
        assertEq(id, id0, "Ready found: id should be id0");
        assertTrue(found, "Ready found: found should be true");

        // Case 5: Ready operation found starting from id1 (startId is inclusive)
        (found, id) = timelockHelper.getNextExecutableOperationId(id1, type(uint256).max);
        assertEq(id, id1, "Ready from id1: id should be id1");
        assertTrue(found, "Ready from id1: found should be true");

        // Case 6: Pagination - when not found, returned id is directly the next startId
        // Cancel id0 and id1 so they won't be found, schedule new not-ready ops
        timelock.cancel(id0);
        timelock.cancel(id1);
        // Schedule 2 new operations with very long delay (not ready)
        bytes32 id4 = _schedule(address(123), 0, data, bytes32(0), keccak256("new0"), 100 days);
        bytes32 id5 = _schedule(address(123), 0, data, bytes32(0), keccak256("new1"), 100 days);
        vm.stopPrank();

        // Now list is: id2 (ready), id3 (ready), id4 (not ready), id5 (not ready)
        // Search with limit 1 starting from beginning - finds id2 immediately
        (found, id) = timelockHelper.getNextExecutableOperationId(bytes32(0), 1);
        assertEq(id, id2, "Pagination case 6a: id should be id2");
        assertTrue(found, "Pagination case 6a: found should be true");

        // Search with limit 1 starting from id4 - checks id4 (not ready), returns id5 (next to check)
        (found, id) = timelockHelper.getNextExecutableOperationId(id4, 1);
        assertEq(id, timelock.getNextOperationId(id4), "Pagination case 6b: id should be next of id4");
        assertFalse(found, "Pagination case 6b: found should be false");

        // Continue from id5 with limit 1 - checks id5 (not ready), id5 is last so returns 0 (exhausted)
        (found, id) = timelockHelper.getNextExecutableOperationId(id5, 1);
        assertEq(id, timelock.getNextOperationId(id5), "Pagination case 6c: id should be next of id5 (0)");
        assertFalse(found, "Pagination case 6c: found should be false");
    }
}
