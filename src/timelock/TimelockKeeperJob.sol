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

import {SkyTimelock} from "./SkyTimelock.sol";

interface IJob {
    function workable(bytes32 network) external returns (bool, bytes memory);
}

/**
 * @title TimelockKeeperJob
 * @dev Keeper job contract for executing ready timelock operations.
 * 
 * This contract implements the dss-cron IJob interface to allow automated
 * execution of ready timelock operations. It iterates through executable
 * operations and executes them one at a time.
 * 
 * Reference: https://github.com/sky-ecosystem/dss-cron/blob/master/src/FlapJob.sol
 */
contract TimelockKeeperJob is IJob {
    SkyTimelock public immutable timelock;

    // --- Events ---
    event Work(bytes32 indexed network, bytes32 indexed operationId);

    /**
     * @param _timelock The SkyTimelock contract to execute operations from.
     */
    constructor(address _timelock) {
        require(_timelock != address(0), "TimelockKeeperJob: zero address");
        timelock = SkyTimelock(payable(_timelock));
    }

    /**
     * @dev Executes the next executable operation.
     * @param network The network identifier (unused, required by IJob interface)
     */
    function work(bytes32 network, bytes calldata) public {
        bytes32 id = timelock.getNextExecutableOperation();
        require(id != bytes32(0), "TimelockKeeperJob: no executable operation");

        // Get operation parameters using the getter function
        // Note: Public mapping getters don't work well with structs containing arrays,
        // so we use the explicit getOperation() function
        SkyTimelock.Operation memory op = timelock.getOperation(id);
        
        // Execute using executeBatch (works for both single and batch operations)
        // Single operations are stored as arrays of length 1
        timelock.executeBatch{value: 0}(op.targets, op.values, op.payloads, op.predecessor, op.salt);
        
        emit Work(network, id);
    }

    /**
     * @dev Returns whether there is work to be done (an executable operation exists).
     * Uses try/catch to test if work() would succeed.
     * @param network The network identifier (unused, required by IJob interface)
     * @return canWork true if work can be executed, false otherwise
     * @return args The arguments to pass to work() (empty bytes)
     */
    function workable(bytes32 network) external override returns (bool canWork, bytes memory args) {
        bytes memory emptyArgs = "";
        
        try this.work(network, emptyArgs) {
            // Work succeeds
            return (true, emptyArgs);
        } catch {
            // Can not work -- carry on
        }
        
        return (false, bytes("No executable operation"));
    }
}

