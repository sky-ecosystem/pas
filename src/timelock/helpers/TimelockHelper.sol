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

interface TimelockLike {
    function isOperationReady(bytes32) external view returns (bool);
    function isOperationDone(bytes32) external view returns (bool);
    function getFirstOperationId() external view returns (bytes32);
    function getNextOperationId(bytes32) external view returns (bytes32);
    function getOperationExists(bytes32) external view returns (bool);
    function getOperationPredecessor(bytes32) external view returns (bytes32);
}

contract TimelockHelper {

    TimelockLike immutable public timelock;

    constructor(address timelock_) {
        timelock = TimelockLike(timelock_);
    }

    // Operations may still not be executable due to various downstream conditions.
    // It is assumed that this is not a perfect fetching mechanism and that if needed proposals
    // can be executed without cron keepers, or canceled in case they are jamming this mechanism.
    // returns - If found: the executable operation. If not found: the next startId to continue from, or bytes32(0) if exhausted.
    function getNextExecutableOperationId(bytes32 startId, uint256 maxIterations) external view returns (bool found, bytes32 id) {
        require(maxIterations > 0, "TimelockHelper/zero-maxIterations");
        require(startId == bytes32(0) || timelock.getOperationExists(startId), "TimelockHelper/invalid-startId");

        id = startId == bytes32(0) ? timelock.getFirstOperationId() : startId;

        uint256 i = 0;
        while (id != bytes32(0) && i++ < maxIterations) {
            if (timelock.isOperationReady(id)) {
                bytes32 predecessor = timelock.getOperationPredecessor(id);
                if (predecessor == bytes32(0) || timelock.isOperationDone(predecessor)) return (true, id);
            }

            id = timelock.getNextOperationId(id);
        }

        return (false, id);
    }
}
