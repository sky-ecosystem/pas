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

import { PASInstance } from "deploy/PASInstance.sol";
import { PASDeploy } from "deploy/PASDeploy.sol";
import { PASInit } from "deploy/PASInit.sol";
import { BeamState } from "src/BeamState.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { PASMom } from "src/PASMom.sol";

interface ChiefLike {
    function hat() external view returns (address);
}

contract PASMomTest is DssTest {
    address constant CHAINLOG = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    DssInstance dss;
    ChiefLike   chief;
    BeamState   beamState;
    Timelock    timelock;
    PASMom      mom;
    address     pauseProxy;

    uint256 constant MIN_DELAY = 1 days;

    event SetOwner(address indexed newOwner);
    event SetAuthority(address indexed newAuthority);
    event StopBeamState();
    event PauseTimelock();

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        dss = MCD.loadFromChainlog(CHAINLOG);
        chief = ChiefLike(dss.chainlog.getAddress("MCD_ADM"));
        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");

        PASInstance memory inst = PASDeploy.deploy(address(this), pauseProxy, MIN_DELAY);
        beamState = BeamState(inst.beamState);
        timelock  = Timelock(payable(inst.timelock));
        mom       = PASMom(inst.mom);

        address[] memory cancellers = new address[](0);
        address[] memory pausers    = new address[](0);

        vm.startPrank(pauseProxy);
        PASInit.init(dss, inst, MIN_DELAY, pauseProxy, cancellers, pausers);
        vm.stopPrank();
    }

    function testDeploy() public view {
        assertEq(address(mom.beamState()), address(beamState));
        assertEq(address(mom.timelock()),  address(timelock));
        assertEq(mom.owner(), pauseProxy);
    }

    function testInit() public view {
        assertEq(beamState.wards(address(mom)), 1);
        assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), address(mom)));
        assertEq(mom.authority(), dss.chainlog.getAddress("MCD_ADM"));
        assertEq(dss.chainlog.getAddress("PAS_MOM"), address(mom));
    }

    function testConstructor() public {
        vm.expectEmit(true, true, true, true);
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

        vm.prank(pauseProxy);
        mom.setAuthority(address(0));
        checkModifier(address(mom), "PASMom/not-authorized", [PASMom.stop.selector, PASMom.pause.selector]);
    }

    function testSetOwner() public {
        vm.prank(pauseProxy);
        vm.expectEmit(true, true, true, true);
        emit SetOwner(address(0x1234));
        mom.setOwner(address(0x1234));
        assertEq(mom.owner(), address(0x1234));
    }

    function testSetAuthority() public {
        vm.prank(pauseProxy);
        vm.expectEmit(true, true, true, true);
        emit SetAuthority(address(0x123));
        mom.setAuthority(address(0x123));
        assertEq(mom.authority(), address(0x123));
    }

    function _checkStop(address who) internal {
        assertEq(beamState.stopped(), false);
        vm.prank(who);
        vm.expectEmit(true, true, true, true);
        emit StopBeamState();
        mom.stop();
        assertEq(beamState.stopped(), true);
    }

    function testStopOwner() public {
        _checkStop(pauseProxy);
    }

    function testStopHat() public {
        _checkStop(chief.hat());
    }

    function _checkPause(address who) internal {
        assertEq(timelock.paused(), false);
        vm.prank(who);
        vm.expectEmit(true, true, true, true);
        emit PauseTimelock();
        mom.pause();
        assertEq(timelock.paused(), true);
    }

    function testPauseOwner() public {
        _checkPause(pauseProxy);
    }

    function testPauseHat() public {
        _checkPause(chief.hat());
    }
}
