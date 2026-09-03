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

pragma solidity >=0.8.0;

interface AccessControlLike {
    function grantRole(bytes32 role, address account) external;
}

// Authorizes the PAS Configurator within a Star's PAU access-control system.
//
// Counterpart to PASInit: whereas PASInit configures the PAS-owned contracts (BeamState,
// Configurator, Timelock), this is run by a Star's governance (the current DEFAULT_ADMIN_ROLE
// holder on its PAU controller stack) to grant the PAS Configurator the admin access it needs
// on the Star's own contracts.
//
// The two grants cover everything the Configurator calls:
//   - accessControls: gates every facet admin setter dispatched via `callControllerAction`
//                     (the controller has no roles of its own; it delegates to AccessControls).
//   - rateLimits:     gates `setRateLimit` (setRateLimitData / setUnlimitedRateLimitData).
//
// NOTE: DEFAULT_ADMIN_ROLE is the OZ role-admin, so each grant makes the Configurator a full
// role-superadmin of that contract (it can grant/revoke any role, including allocators). This
// is the intended trust model but has a wide blast radius; the security of these roles rests
// entirely on the timelock/cBeam/BeamState gating in front of the Configurator.
library PASAuthorizeInPAU {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    function authorize(
        address configurator,
        address accessControls,
        address rateLimits
    ) internal {
        AccessControlLike(accessControls).grantRole(DEFAULT_ADMIN_ROLE, configurator);
        AccessControlLike(rateLimits).grantRole(DEFAULT_ADMIN_ROLE, configurator);
    }
}
