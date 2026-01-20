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

// TODO: import this from dss-cron/src/interfaces once porting this contract
interface IJob {
    function work(bytes32 network, bytes calldata args) external;
    function workable(bytes32 network) external returns (bool canWork, bytes memory args);
}

interface SequencerLike {
    function isMaster(bytes32 network) external view returns (bool);
}

interface TimelockLike {
    struct Operation {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 predecessor;
        bytes32 salt;
    }

    function getNextExecutableOperation(uint256 startIndex, uint256 maxIterations) external view returns (bytes32 id);
    function getOperation(bytes32 id) external view returns (Operation memory op);
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;
}

contract TimelockKeeperJob is IJob {

    SequencerLike public immutable sequencer;
    TimelockLike  public immutable timelock;
    uint256       public immutable maxIterations;

    // --- Errors ---
    error NotMaster(bytes32 network);
    error NoExecutableOperation();

    // --- Events ---
    event Work(bytes32 indexed network, bytes32 indexed operationId);

    constructor(address _sequencer, address _timelock, uint256 _maxIterations) {
        sequencer     = SequencerLike(_sequencer);
        timelock      = TimelockLike(_timelock);
        maxIterations = _maxIterations;
    }

    function work(bytes32 network, bytes calldata) external override {
        if (!sequencer.isMaster(network)) revert NotMaster(network);

        bytes32 id = timelock.getNextExecutableOperation(0, maxIterations);
        if (id == bytes32(0)) revert NoExecutableOperation();

        TimelockLike.Operation memory op = timelock.getOperation(id);
        
        // Assume that in case a proposal needs eth the timelock is pre-funded, or alternatively it is executed manually 
        timelock.executeBatch{value: 0}(op.targets, op.values, op.payloads, op.predecessor, op.salt);
        
        emit Work(network, id);
    }

    function workable(bytes32 network) external override returns (bool, bytes memory) {
        if (!sequencer.isMaster(network)) return (false, bytes("Network is not master"));

        bytes memory args = "";
        try this.work(network, args) {
            // Work succeeds
            return (true, args);
        } catch {
            // Can not work -- carry on
        }

        return (false, bytes("No executable operation"));
    }
}

