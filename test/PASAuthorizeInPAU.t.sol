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

import { PASAuthorizeInPAU } from "deploy/PASAuthorizeInPAU.sol";

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { IAccessControl }          from "@openzeppelin/contracts/access/IAccessControl.sol";

// Minimal stand-in for a PAU AccessControls / RateLimits contract: both are stock OZ
// AccessControl to this library, so one mock serves for both roles.
contract MockAccessControlled is AccessControlEnumerable {
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }
}

// Stands in for the Star's governance spell: `authorize` is an internal library function, so it
// inlines here and `grantRole` is called with msg.sender == this harness. The harness must hold
// DEFAULT_ADMIN_ROLE on the targets, mirroring the Star proxy in production.
contract Authorizer {
    function run(address configurator, address accessControls, address rateLimits) external {
        PASAuthorizeInPAU.authorize(configurator, accessControls, rateLimits);
    }
}

contract PASAuthorizeInPAUTest is DssTest {
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    Authorizer authorizer;
    address    configurator;

    function setUp() public {
        authorizer   = new Authorizer();
        configurator = makeAddr("configurator");
    }

    function testAuthorizeGrantsBothRoles() public {
        MockAccessControlled accessControls = new MockAccessControlled(address(authorizer));
        MockAccessControlled rateLimits     = new MockAccessControlled(address(authorizer));

        // Pre-state: the configurator holds nothing.
        assertFalse(accessControls.hasRole(DEFAULT_ADMIN_ROLE, configurator));
        assertFalse(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, configurator));

        authorizer.run(configurator, address(accessControls), address(rateLimits));

        // Both targets are granted, not just one.
        assertTrue(accessControls.hasRole(DEFAULT_ADMIN_ROLE, configurator));
        assertTrue(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, configurator));
    }

    function testAuthorizeRevertsWhenGrantorNotAdminOnAccessControls() public {
        // accessControls admin is someone else -> the first grant reverts.
        MockAccessControlled accessControls = new MockAccessControlled(makeAddr("otherAdmin"));
        MockAccessControlled rateLimits     = new MockAccessControlled(address(authorizer));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(authorizer),
                DEFAULT_ADMIN_ROLE
            )
        );
        authorizer.run(configurator, address(accessControls), address(rateLimits));
    }

    function testAuthorizeRevertsWhenGrantorNotAdminOnRateLimits() public {
        // accessControls grant succeeds, then the rateLimits grant reverts (and rolls back).
        MockAccessControlled accessControls = new MockAccessControlled(address(authorizer));
        MockAccessControlled rateLimits     = new MockAccessControlled(makeAddr("otherAdmin"));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(authorizer),
                DEFAULT_ADMIN_ROLE
            )
        );
        authorizer.run(configurator, address(accessControls), address(rateLimits));

        // The whole call reverted, so the earlier accessControls grant did not persist.
        assertFalse(accessControls.hasRole(DEFAULT_ADMIN_ROLE, configurator));
    }
}
