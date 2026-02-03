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

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Bytes32LinkedList } from "./Bytes32LinkedList.sol";

contract Timelock is TimelockController, Pausable {
    using Bytes32LinkedList for Bytes32LinkedList.List;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Operation tracking for keeper jobs - store parameters for execution
    struct Operation {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 predecessor;
        bytes32 salt;
    }

    Bytes32LinkedList.List           internal _operationIds;
    mapping(bytes32 id => Operation) internal _operations;

    // Changes from original timelock:
    // - Do not allow proposers to change admin-only configurations
    // - Make execution permissionless
    // - Add pausing logic
    // - Allow admin to change the min delay immediately
    // - Do not allow proposals to change the min delay

    // Notes:
    // - By default all proposers can also cancel any proposal, this should be taken into account to make sure that they are trusted and that specific cancellations do not cause big harm.
    // - Cancellers can cancel any proposal, not only ones they created. Same assumptions as above apply.

    constructor(
        uint256 minDelay,
        address admin
    ) TimelockController(minDelay, new address[](0), new address[](0), admin) {
        require(admin != address(0), "Timelock/admin-zero-address");

        _revokeRole(DEFAULT_ADMIN_ROLE, address(this)); // do not allow proposers to change admin-only configurations
        _grantRole(EXECUTOR_ROLE, address(0)); // allow anyone to execute
    }

    // ------------------------------------------------------------------------
    // Pausing logic
    // ------------------------------------------------------------------------

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------------
    // Delay management
    // ------------------------------------------------------------------------

    // Can not override updateDelay as we need an external call to the inherited function to change msg.sender.
    function updateDelayImmediately(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        this.updateDelay(newDelay);
    }

    // ------------------------------------------------------------------------
    // Scheduling (blocked while paused)
    // ------------------------------------------------------------------------

    function schedule(address, uint256, bytes calldata, bytes32, bytes32, uint256) public pure override {
        revert("Timelock/use-scheduleBatch");
    }

    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public virtual override whenNotPaused {
        for (uint256 i = 0; i < targets.length; ++i) {
            require(targets[i] != address(this), "Timelock/self-calls-disabled");
        }
        
        super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        
        // Track operation for keeper jobs
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
        _operationIds.add(id);
        _operations[id] = Operation(targets, values, payloads, predecessor, salt);
    }

    // As unpausing requires an admin action anyway, it is fine to block canceling while paused.
    // If needed, the admin can atomically cancel any proposal right after unpausing.
    function cancel(bytes32 id) public virtual override whenNotPaused {
        super.cancel(id);
        _operationIds.remove(id);
        delete _operations[id];
    }

    // ------------------------------------------------------------------------
    // Execution (blocked while paused)
    // ------------------------------------------------------------------------

    function execute(address, uint256, bytes calldata, bytes32, bytes32) public payable override {
        revert("Timelock/use-executeBatch");
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) public payable virtual override whenNotPaused {
        super.executeBatch(targets, values, payloads, predecessor, salt);
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
        _operationIds.remove(id);
        delete _operations[id];
    }

    // ------------------------------------------------------------------------
    // Keeper job helpers
    // ------------------------------------------------------------------------

    function getOperationCount() external view returns (uint256) {
        return _operationIds.count;
    }

    function getOperationExists(bytes32 id) external view returns (bool) {
        return _operationIds.exists[id];
    }

    function getPrevOperationId(bytes32 id) external view returns (bytes32) {
        return _operationIds.nodes[id].prev;
    }

    function getNextOperationId(bytes32 id) external view returns (bytes32) {
        return _operationIds.nodes[id].next;
    }

    function getFirstOperationId() external view returns (bytes32) {
        return _operationIds.first;
    }

    function getLastOperationId() external view returns (bytes32) {
        return _operationIds.last;
    }

    // Operations may still not be executable due to various downstream conditions.
    // It is assumed that this is not a perfect fetching mechanism and that if needed proposals
    // can be executed without cron keepers, or canceled in case they are jamming this mechanism.
    /// @notice Find the next executable operation in the queue
    /// @param startAfterId Start searching after this operation ID. Use bytes32(0) to start from the beginning.
    /// @param maxIterations Maximum number of operations to check. Use any big number, such as type(uint256).max, for no practical limit.
    /// @return id The ID of the next executable operation, or bytes32(0) if none found
    function getNextExecutableOperationId(bytes32 startAfterId, uint256 maxIterations) external view returns (bytes32 id) {
        require(maxIterations > 0, "Timelock/zero-maxIterations");
        bytes32 operationId = startAfterId == bytes32(0) ? _operationIds.first : _operationIds.nodes[startAfterId].next;

        uint256 iterations;
        while (operationId != bytes32(0) && iterations < maxIterations) {
            // Check if operation is ready
            if (isOperationReady(operationId)) {
                // Check if predecessor is done, if any
                bytes32 predecessor = _operations[operationId].predecessor;
                if (predecessor == bytes32(0) || isOperationDone(predecessor)) {
                    return operationId;
                }
            }

            operationId = _operationIds.nodes[operationId].next;
            iterations++;
        }

        return bytes32(0);
    }

    function getOperation(bytes32 id) external view returns (Operation memory op) {
        return _operations[id];
    }
}

