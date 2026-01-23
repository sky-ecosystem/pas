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

interface AuthorityLike {
    function canCall(address src, address dst, bytes4 sig) external view returns (bool);
}

interface BeamStateLike {
    function stop() external;
}

interface TimelockLike {
    function pause() external;
}

contract PASMom {

    // --- Storage variables ---

    address public owner;
    address public authority;

    // --- Immutables ---

    BeamStateLike public immutable beamState;
    TimelockLike  public immutable timelock;

    // --- Events ---

    event SetOwner(address indexed newOwner);
    event SetAuthority(address indexed newAuthority);
    event Stop();
    event Pause();

    // --- Modifiers ---

    modifier onlyOwner() {
        require(msg.sender == owner, "PASMom/not-owner");
        _;
    }

    modifier auth() {
        require(isAuthorized(msg.sender, msg.sig), "PASMom/not-authorized");
        _;
    }

    // --- Constructor ---

    constructor(address beamState_, address timelock_) {
        beamState = BeamStateLike(beamState_);
        timelock  = TimelockLike(timelock_);

        owner = msg.sender;
        emit SetOwner(msg.sender);
    }

    // --- Internal functions ---

    function isAuthorized(address src, bytes4 sig) internal view returns (bool) {
        if (src == owner) {
            return true;
        } else if (authority != address(0)) {
            return AuthorityLike(authority).canCall(src, address(this), sig);
        }
        return false;
    }

    // --- Admin functions ---

    function setOwner(address owner_) external onlyOwner {
        owner = owner_;
        emit SetOwner(owner_);
    }

    function setAuthority(address authority_) external onlyOwner {
        authority = authority_;
        emit SetAuthority(authority_);
    }

    // --- Emergency functions ---

    function stop() external auth {
        beamState.stop();
        emit Stop();
    }

    function pause() external auth {
        timelock.pause();
        emit Pause();
    }
}
