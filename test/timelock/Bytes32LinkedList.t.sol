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
import { Bytes32LinkedList } from "src/timelock/Bytes32LinkedList.sol";

contract LinkedListWrapper {
    using Bytes32LinkedList for Bytes32LinkedList.List;

    Bytes32LinkedList.List internal list;

    function add(bytes32 id) external returns (bool) {
        return list.add(id);
    }

    function remove(bytes32 id) external returns (bool) {
        return list.remove(id);
    }

    function exists(bytes32 id) external view returns (bool) {
        return list.exists[id];
    }

    function count() external view returns (uint256) {
        return list.count;
    }

    function first() external view returns (bytes32) {
        return list.first;
    }

    function last() external view returns (bytes32) {
        return list.last;
    }

    function prev(bytes32 id) external view returns (bytes32) {
        return list.nodes[id].prev;
    }

    function next(bytes32 id) external view returns (bytes32) {
        return list.nodes[id].next;
    }
}

contract Bytes32LinkedListTest is Test {
    LinkedListWrapper public wrapper;

    bytes32 public constant ID_A = keccak256("A");
    bytes32 public constant ID_B = keccak256("B");
    bytes32 public constant ID_C = keccak256("C");
    bytes32 public constant ID_D = keccak256("D");

    function setUp() public {
        wrapper = new LinkedListWrapper();
    }

    // ============================================================================
    // Empty List Tests
    // ============================================================================

    function testEmptyListState() public view {
        assertEq(wrapper.count(), 0);
        assertEq(wrapper.first(), bytes32(0));
        assertEq(wrapper.last(), bytes32(0));
        assertFalse(wrapper.exists(ID_A));
    }

    function testRemoveFromEmptyList() public {
        bool success = wrapper.remove(ID_A);
        assertFalse(success);
        assertEq(wrapper.count(), 0);
    }

    // ============================================================================
    // Add Tests
    // ============================================================================

    function testAddSingleElement() public {
        bool success = wrapper.add(ID_A);

        assertTrue(success);
        assertEq(wrapper.count(), 1);
        assertEq(wrapper.first(), ID_A);
        assertEq(wrapper.last(), ID_A);
        assertTrue(wrapper.exists(ID_A));
        assertEq(wrapper.prev(ID_A), bytes32(0));
        assertEq(wrapper.next(ID_A), bytes32(0));
    }

    function testAddTwoElements() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);

        assertEq(wrapper.count(), 2);
        assertEq(wrapper.first(), ID_A);
        assertEq(wrapper.last(), ID_B);

        // A <-> B
        assertEq(wrapper.prev(ID_A), bytes32(0));
        assertEq(wrapper.next(ID_A), ID_B);
        assertEq(wrapper.prev(ID_B), ID_A);
        assertEq(wrapper.next(ID_B), bytes32(0));
    }

    function testAddThreeElements() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        assertEq(wrapper.count(), 3);
        assertEq(wrapper.first(), ID_A);
        assertEq(wrapper.last(), ID_C);

        // A <-> B <-> C
        assertEq(wrapper.prev(ID_A), bytes32(0));
        assertEq(wrapper.next(ID_A), ID_B);
        assertEq(wrapper.prev(ID_B), ID_A);
        assertEq(wrapper.next(ID_B), ID_C);
        assertEq(wrapper.prev(ID_C), ID_B);
        assertEq(wrapper.next(ID_C), bytes32(0));
    }

    function testAddDuplicateReturnsFalse() public {
        assertTrue(wrapper.add(ID_A));
        assertFalse(wrapper.add(ID_A));

        assertEq(wrapper.count(), 1);
    }

    function testAddingBytes32ZeroReverts() public {
        vm.expectRevert("id-null");
        wrapper.add(bytes32(0));
    }

    // ============================================================================
    // Remove Tests
    // ============================================================================

    function testRemoveSingleElement() public {
        wrapper.add(ID_A);

        bool success = wrapper.remove(ID_A);

        assertTrue(success);
        assertEq(wrapper.count(), 0);
        assertEq(wrapper.first(), bytes32(0));
        assertEq(wrapper.last(), bytes32(0));
        assertFalse(wrapper.exists(ID_A));
    }

    function testRemoveFirstOfTwo() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);

        wrapper.remove(ID_A);

        assertEq(wrapper.count(), 1);
        assertEq(wrapper.first(), ID_B);
        assertEq(wrapper.last(), ID_B);
        assertFalse(wrapper.exists(ID_A));
        assertTrue(wrapper.exists(ID_B));
        assertEq(wrapper.prev(ID_B), bytes32(0));
        assertEq(wrapper.next(ID_B), bytes32(0));
    }

    function testRemoveLastOfTwo() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);

        wrapper.remove(ID_B);

        assertEq(wrapper.count(), 1);
        assertEq(wrapper.first(), ID_A);
        assertEq(wrapper.last(), ID_A);
        assertTrue(wrapper.exists(ID_A));
        assertFalse(wrapper.exists(ID_B));
        assertEq(wrapper.prev(ID_A), bytes32(0));
        assertEq(wrapper.next(ID_A), bytes32(0));
    }

    function testRemoveMiddleOfThree() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        wrapper.remove(ID_B);

        assertEq(wrapper.count(), 2);
        assertEq(wrapper.first(), ID_A);
        assertEq(wrapper.last(), ID_C);
        assertTrue(wrapper.exists(ID_A));
        assertFalse(wrapper.exists(ID_B));
        assertTrue(wrapper.exists(ID_C));

        // A <-> C (B removed)
        assertEq(wrapper.prev(ID_A), bytes32(0));
        assertEq(wrapper.next(ID_A), ID_C);
        assertEq(wrapper.prev(ID_C), ID_A);
        assertEq(wrapper.next(ID_C), bytes32(0));
    }

    function testRemoveFirstOfThree() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        wrapper.remove(ID_A);

        assertEq(wrapper.count(), 2);
        assertEq(wrapper.first(), ID_B);
        assertEq(wrapper.last(), ID_C);

        // B <-> C
        assertEq(wrapper.prev(ID_B), bytes32(0));
        assertEq(wrapper.next(ID_B), ID_C);
        assertEq(wrapper.prev(ID_C), ID_B);
        assertEq(wrapper.next(ID_C), bytes32(0));
    }

    function testRemoveLastOfThree() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        wrapper.remove(ID_C);

        assertEq(wrapper.count(), 2);
        assertEq(wrapper.first(), ID_A);
        assertEq(wrapper.last(), ID_B);

        // A <-> B
        assertEq(wrapper.prev(ID_A), bytes32(0));
        assertEq(wrapper.next(ID_A), ID_B);
        assertEq(wrapper.prev(ID_B), ID_A);
        assertEq(wrapper.next(ID_B), bytes32(0));
    }

    function testRemoveNonExistentReturnsFalse() public {
        wrapper.add(ID_A);

        bool success = wrapper.remove(ID_B);

        assertFalse(success);
        assertEq(wrapper.count(), 1);
    }

    function testRemoveAlreadyRemovedReturnsFalse() public {
        wrapper.add(ID_A);
        wrapper.remove(ID_A);

        bool success = wrapper.remove(ID_A);

        assertFalse(success);
        assertEq(wrapper.count(), 0);
    }

    // ============================================================================
    // Order Preservation Tests
    // ============================================================================

    function testOrderPreservedAfterMiddleRemoval() public {
        // Add A, B, C, D
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);
        wrapper.add(ID_D);

        // Remove B and C
        wrapper.remove(ID_B);
        wrapper.remove(ID_C);

        // Should have A <-> D
        assertEq(wrapper.count(), 2);
        assertEq(wrapper.first(), ID_A);
        assertEq(wrapper.last(), ID_D);
        assertEq(wrapper.next(ID_A), ID_D);
        assertEq(wrapper.prev(ID_D), ID_A);
    }

    function testCanReaddRemovedElement() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.remove(ID_A);

        // Re-add A, should go to end
        assertTrue(wrapper.add(ID_A));

        assertEq(wrapper.count(), 2);
        assertEq(wrapper.first(), ID_B);
        assertEq(wrapper.last(), ID_A);

        // B <-> A
        assertEq(wrapper.next(ID_B), ID_A);
        assertEq(wrapper.prev(ID_A), ID_B);
    }

    // ============================================================================
    // Traversal Tests
    // ============================================================================

    function testForwardTraversal() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        bytes32 current = wrapper.first();
        assertEq(current, ID_A);

        current = wrapper.next(current);
        assertEq(current, ID_B);

        current = wrapper.next(current);
        assertEq(current, ID_C);

        current = wrapper.next(current);
        assertEq(current, bytes32(0));
    }

    function testBackwardTraversal() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        bytes32 current = wrapper.last();
        assertEq(current, ID_C);

        current = wrapper.prev(current);
        assertEq(current, ID_B);

        current = wrapper.prev(current);
        assertEq(current, ID_A);

        current = wrapper.prev(current);
        assertEq(current, bytes32(0));
    }

    // ============================================================================
    // Edge Cases
    // ============================================================================

    function testRemoveAllElementsOneByOne() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        wrapper.remove(ID_A);
        assertEq(wrapper.count(), 2);
        assertEq(wrapper.first(), ID_B);
        assertEq(wrapper.last(), ID_C);

        wrapper.remove(ID_B);
        assertEq(wrapper.count(), 1);
        assertEq(wrapper.first(), ID_C);
        assertEq(wrapper.last(), ID_C);

        wrapper.remove(ID_C);
        assertEq(wrapper.count(), 0);
        assertEq(wrapper.first(), bytes32(0));
        assertEq(wrapper.last(), bytes32(0));
    }

    function testRemoveInReverseOrder() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        wrapper.remove(ID_C);
        assertEq(wrapper.last(), ID_B);

        wrapper.remove(ID_B);
        assertEq(wrapper.last(), ID_A);

        wrapper.remove(ID_A);
        assertEq(wrapper.count(), 0);
    }

    function testNodeCleanupAfterRemoval() public {
        wrapper.add(ID_A);
        wrapper.add(ID_B);
        wrapper.add(ID_C);

        wrapper.remove(ID_B);

        // B's node data should be cleared
        assertEq(wrapper.prev(ID_B), bytes32(0));
        assertEq(wrapper.next(ID_B), bytes32(0));
        assertFalse(wrapper.exists(ID_B));
    }
}
