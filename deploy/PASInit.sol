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

import { PASInstance } from "./PASInstance.sol";

interface BeamStateLike {
    function setUserRole(address, uint8, bool) external;
    function setRoleAction(uint8, bytes4, bool) external;
    function stop() external;
    function start() external;
    function setHop(address, uint256) external;
    function setMaxChange(address, uint256) external;
    function addRateLimits(address) external;
    function delRateLimits(address) external;
    function addController(address) external;
    function delController(address) external;
    function addCBeam(address) external;
    function delCBeam(address) external;
    function setCBeamForRateLimits(address, address) external;
    function unsetCBeamForRateLimits(address, address) external;
    function setCBeamForController(address, address) external;
    function unsetCBeamForController(address, address) external;
    function addInitRateLimits(bytes32, address, uint256, uint256) external;
    function delInitRateLimits(bytes32, address) external;
    function addInitControllerActions(bytes calldata data, address) external;
    function delInitControllerActions(bytes32, address) external;
}

interface ConfiguratorLike {
    function beamState() external view returns (address);
}

interface TimelockLike {
    function getMinDelay() external view returns (uint256);
    function PROPOSER_ROLE() external view returns (bytes32);
    function CANCELLER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function grantRole(bytes32, address) external;
}

interface TimelockWrapperLike {
    function timelock() external view returns (address);
    function beamState() external view returns (address);
    function kiss(address) external;
}

library PASInit {
    uint256 constant internal WAD = 10**18;

    function init(
        PASInstance memory pasInstance,
        uint256            minDelay,
        address            coreCouncil,
        address[]   memory cancellers,
        address[]   memory pausers
    ) internal {
        BeamStateLike       beamState       = BeamStateLike(pasInstance.beamState);
        ConfiguratorLike    configurator    = ConfiguratorLike(pasInstance.configurator);
        TimelockLike        timelock        = TimelockLike(pasInstance.timelock);
        TimelockWrapperLike timelockWrapper = TimelockWrapperLike(pasInstance.timelockWrapper);

        // --- Sanity checks ---

        require(configurator.beamState()    == address(beamState),    "PASInit/configurator-beamState-mismatch");
        require(timelock.getMinDelay()      == minDelay,              "PASInit/timelock-minDelay-mismatch");
        require(timelockWrapper.timelock()  == address(timelock),     "PASInit/wrapper-timelock-mismatch");
        require(timelockWrapper.beamState() == address(beamState),    "PASInit/wrapper-beamState-mismatch");

        // --- Configure BeamState ---

        // Define Beam actions that are accessed through timelock (role 1) and directly (role 2)
        beamState.setRoleAction(1, BeamStateLike.start.selector,                    true);
        beamState.setRoleAction(1, BeamStateLike.setHop.selector,                   true);
        beamState.setRoleAction(1, BeamStateLike.setMaxChange.selector,             true);
        beamState.setRoleAction(1, BeamStateLike.addRateLimits.selector,            true);
        beamState.setRoleAction(1, BeamStateLike.addController.selector,            true);
        beamState.setRoleAction(1, BeamStateLike.addCBeam.selector,                 true);
        beamState.setRoleAction(1, BeamStateLike.addInitRateLimits.selector,        true);
        beamState.setRoleAction(1, BeamStateLike.addInitControllerActions.selector, true);
        beamState.setRoleAction(2, BeamStateLike.stop.selector,                     true);
        beamState.setRoleAction(2, BeamStateLike.delRateLimits.selector,            true);
        beamState.setRoleAction(2, BeamStateLike.delController.selector,            true);
        beamState.setRoleAction(2, BeamStateLike.delCBeam.selector,                 true);
        beamState.setRoleAction(2, BeamStateLike.setCBeamForRateLimits.selector,    true);
        beamState.setRoleAction(2, BeamStateLike.unsetCBeamForRateLimits.selector,  true);
        beamState.setRoleAction(2, BeamStateLike.setCBeamForController.selector,    true);
        beamState.setRoleAction(2, BeamStateLike.unsetCBeamForController.selector,  true);
        beamState.setRoleAction(2, BeamStateLike.delInitRateLimits.selector,        true);
        beamState.setRoleAction(2, BeamStateLike.delInitControllerActions.selector, true);

        // Set timelock as the user with role 1 and coreCouncil as the one with role 2
        beamState.setUserRole(address(timelock), 1, true);
        beamState.setUserRole(coreCouncil,       2, true);

        // --- Configure Timelock and Wrapper ---

        // Grant the coreCouncil as the proposer in the timelock either directly or through the wrapper
        // Grant cancellers and pausers in timelock with their respective roles
        timelock.grantRole(timelock.PROPOSER_ROLE(),  coreCouncil);
        timelock.grantRole(timelock.PROPOSER_ROLE(),  address(timelockWrapper));
        timelock.grantRole(timelock.CANCELLER_ROLE(), coreCouncil);
        for (uint256 i = 0; i < cancellers.length; ++i) {
            timelock.grantRole(timelock.CANCELLER_ROLE(), cancellers[i]);
        }
        for (uint256 i = 0; i < pausers.length; ++i) {
            timelock.grantRole(timelock.PAUSER_ROLE(), pausers[i]);
        }
        timelockWrapper.kiss(coreCouncil);
    }
}
