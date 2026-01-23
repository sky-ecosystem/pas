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

import "dss-test/DssTest.sol";

import { BeamState } from "src/BeamState.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { PASMom } from "src/PASMom.sol";

contract MockChief {
    address hat;

    constructor(address hat_) {
        hat = hat_;
    }

    function canCall(address caller, address, bytes4) external view returns (bool ok) {
        ok = caller == hat;
    }
}

contract PASMomTest is DssTest {
    address     owner;
    address     hat;
    MockChief   chief;
    BeamState   beamState;
    Timelock    timelock;
    PASMom      mom;

    uint256 constant MIN_DELAY = 1 days;

    event SetOwner(address indexed newOwner);
    event SetAuthority(address indexed newAuthority);
    event StopBeamState();
    event PauseTimelock();

    function setUp() public {
        owner = makeAddr("owner");
        hat = makeAddr("hat");
        chief = new MockChief(hat);

        vm.startPrank(owner);
        beamState = new BeamState();
        timelock  = new Timelock(MIN_DELAY, owner);
        mom       = new PASMom(address(beamState), address(timelock));

        beamState.rely(address(mom));
        timelock.grantRole(timelock.PAUSER_ROLE(), address(mom));
        mom.setAuthority(address(chief));
        vm.stopPrank();
    }

    function testConstructor() public {
        vm.expectEmit();
        emit SetOwner(address(this));
        PASMom mom2 = new PASMom(address(beamState), address(timelock));

        assertEq(address(mom2.beamState()), address(beamState));
        assertEq(address(mom2.timelock()),  address(timelock));
        assertEq(mom2.owner(), address(this));
    }

    function testOnlyOwnerMethods() public {
        checkModifier(
            address(mom), "PASMom/not-owner", [PASMom.setOwner.selector, PASMom.setAuthority.selector]
        );
    }

    function testAuthMethods() public {
        checkModifier(address(mom), "PASMom/not-authorized", [PASMom.stop.selector, PASMom.pause.selector]);

        vm.prank(owner);
        mom.setAuthority(address(0));
        checkModifier(address(mom), "PASMom/not-authorized", [PASMom.stop.selector, PASMom.pause.selector]);
    }

    function testSetOwner() public {
        vm.prank(owner);
        vm.expectEmit();
        emit SetOwner(address(0x1234));
        mom.setOwner(address(0x1234));
        assertEq(mom.owner(), address(0x1234));
    }

    function testSetAuthority() public {
        vm.prank(owner);
        vm.expectEmit();
        emit SetAuthority(address(0x123));
        mom.setAuthority(address(0x123));
        assertEq(mom.authority(), address(0x123));
    }

    function _checkStop(address who) internal {
        assertEq(beamState.stopped(), false);
        vm.prank(who);
        vm.expectEmit();
        emit StopBeamState();
        mom.stop();
        assertEq(beamState.stopped(), true);
    }

    function testStopOwner() public {
        _checkStop(owner);
    }

    function testStopHat() public {
        _checkStop(hat);
    }

    function _checkPause(address who) internal {
        assertEq(timelock.paused(), false);
        vm.prank(who);
        vm.expectEmit();
        emit PauseTimelock();
        mom.pause();
        assertEq(timelock.paused(), true);
    }

    function testPauseOwner() public {
        _checkPause(owner);
    }

    function testPauseHat() public {
        _checkPause(hat);
    }
}
