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
import { L2PASSpell } from "deploy/L2PASSpell.sol";
import { BeamState } from "src/BeamState.sol";
import { Timelock } from "src/timelock/Timelock.sol";

// Minimal stand-in for the governance proxy that the L2GovernanceRelay executes spells through.
// It holds the admin/ward roles and delegatecalls into the spell, so inside the spell `address(this)`
// (and the msg.sender of its calls) is this proxy - mirroring real spell execution.
contract MockGovProxy {
    function exec(address spell, bytes memory data) external {
        (bool ok, bytes memory ret) = spell.delegatecall(data);
        if (!ok) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
    }
}

contract L2PASSpellTest is DssTest {

    PASInstance  pas;
    MockGovProxy proxy;
    L2PASSpell   spell;
    Timelock     timelock;

    address coreCouncil = address(0x1);

    uint256 constant MIN_DELAY = 1 days;

    function setUp() public {
        proxy = new MockGovProxy();

        // Deploy PAS owned by the proxy: switchOwner relies the proxy on BeamState and the Timelock
        // is constructed with the proxy as admin - exactly the roles the spell relies on at execution.
        pas = PASDeploy.deploy(address(this), address(proxy), MIN_DELAY);
        timelock = Timelock(payable(pas.timelock));

        spell = new L2PASSpell(pas.beamState, pas.configurator, pas.timelock);
    }

    // Runs the spell the way the relay would: the proxy delegatecalls into it.
    function _init(bool startPaused) internal {
        proxy.exec(
            address(spell),
            abi.encodeCall(L2PASSpell.init, (MIN_DELAY, coreCouncil, new address[](0), new address[](0), startPaused))
        );
    }

    function testInitOperational() public {
        _init(false);

        assertFalse(timelock.paused(), "timelock should not be paused");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), coreCouncil), "coreCouncil should be proposer");
        assertTrue(BeamState(pas.beamState).hasUserRole(address(timelock), uint8(1)), "timelock should have DELAYED role");
    }

    function testInitStartPaused() public {
        _init(true);

        assertTrue(timelock.paused(), "timelock should be paused");
        // The proxy temporarily held PAUSER_ROLE to pause; it must not retain it.
        assertFalse(timelock.hasRole(timelock.PAUSER_ROLE(), address(proxy)), "proxy should not retain PAUSER_ROLE");
        // Still fully configured despite being paused.
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), coreCouncil), "coreCouncil should be proposer");
    }
}
