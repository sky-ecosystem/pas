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

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Timelock is TimelockController, Pausable {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Operation tracking for keeper jobs - store parameters for execution
    struct Operation {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 predecessor;
        bytes32 salt;
    }

    EnumerableSet.Bytes32Set private _operationIds;
    mapping(bytes32 id => Operation) public operations; // Public for keeper access

    // Changes from original timelock:
    // - Do not allow proposers to change admin-only configurations
    // - Support adding cancellers which are not proposers
    // - Make execution permissionless
    // - Add pausing logic
    // - Allow admin to change the delay immediately
    // - Do not allow proposals to change the delay

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
        uint256 len = targets.length;
        for (uint256 i = 0; i < len; ++i) {
            require(targets[i] != address(this), "Timelock/self-calls-disabled");
        }
        
        super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        
        // Track operation for keeper jobs
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
        _operationIds.add(id);
        operations[id] = Operation(targets, values, payloads, predecessor, salt);
    }

    function cancel(bytes32 id) public virtual override whenNotPaused {
        super.cancel(id);
        _operationIds.remove(id);
        delete operations[id];
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
        delete operations[id];
    }

    // ------------------------------------------------------------------------
    // Keeper job helpers
    // ------------------------------------------------------------------------

    // Operations may still not be executable due to various downstream conditions.
    // It is assumed that this is not a perfect fetching mechanism and that if needed proposals
    // can be executed without cron keepers, or canceled in case they are jamming this mechanism.
    function getNextExecutableOperation(uint256 startIndex, uint256 maxIterations) external view returns (bytes32 id) {
        uint256 length = _operationIds.length();
        if (startIndex >= length) return bytes32(0);

        // Safe: if maxIterations is 0 (no limit) or exceeds remaining operations, scan to end
        uint256 remaining = length - startIndex;
        uint256 endIndex = (maxIterations == 0 || maxIterations > remaining) ? length : startIndex + maxIterations;

        for (uint256 i = startIndex; i < endIndex; ++i) {
            bytes32 operationId = _operationIds.at(i);

            // Check if operation is ready
            if (!isOperationReady(operationId)) continue;

            // Check if predecessor is done, if any
            Operation memory op = operations[operationId];
            if (op.predecessor != bytes32(0) && !isOperationDone(op.predecessor)) continue;

            return operationId;
        }

        return bytes32(0);
    }

    function getOperationIndex(bytes32 id) external view returns (bool exists, uint256 index) {
        uint256 position = _operationIds._inner._positions[id];
        if (position == 0) {
            return (false, 0);
        }
        return (true, position - 1);
    }

    function getOperationCount() external view returns (uint256) {
        return _operationIds.length();
    }

    function getOperation(bytes32 id) external view returns (Operation memory op) {
        return operations[id];
    }
}

