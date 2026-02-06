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

/// @title Bytes32LinkedList
/// @notice A double linked list library for bytes32 values
library Bytes32LinkedList {
    struct Node {
        bytes32 prev;
        bytes32 next;
    }

    struct List {
        bytes32 first;
        bytes32 last;
        uint256 count;
        mapping(bytes32 => Node) nodes;
        mapping(bytes32 => bool) exists;
    }

    /// @notice Add a new item to the end of the list
    /// @param list The list to add to
    /// @param id The bytes32 value to add
    /// @return success True if the item was added, false if it is bytes32(0) or already exists
    function add(List storage list, bytes32 id) internal returns (bool success) {
        if (id == bytes32(0) || list.exists[id]) {
            return false;
        }

        list.exists[id] = true;
        list.count++;

        if (list.first == bytes32(0)) {
            // First item in the list
            list.first = id;
            list.last = id;
        } else {
            // Append to end
            list.nodes[id].prev = list.last;
            list.nodes[list.last].next = id;
            list.last = id;
        }

        return true;
    }

    /// @notice Remove an item from the list
    /// @param list The list to remove from
    /// @param id The bytes32 value to remove
    /// @return success True if the item was removed, false if it didn't exist
    function remove(List storage list, bytes32 id) internal returns (bool success) {
        if (!list.exists[id]) {
            return false;
        }

        Node storage node = list.nodes[id];
        bytes32 prevId = node.prev;
        bytes32 nextId = node.next;

        // Update prev node's next pointer
        if (prevId != bytes32(0)) {
            list.nodes[prevId].next = nextId;
        } else {
            // Removing first element
            list.first = nextId;
        }

        // Update next node's prev pointer
        if (nextId != bytes32(0)) {
            list.nodes[nextId].prev = prevId;
        } else {
            // Removing last element
            list.last = prevId;
        }

        // Clean up
        delete list.nodes[id];
        list.exists[id] = false;
        list.count--;

        return true;
    }
}
