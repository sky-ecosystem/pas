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

import { DssInstance } from "dss-test/MCD.sol";
import { PASInstance } from "./PASInstance.sol";

interface BeamStateLike {
    function rely(address) external;
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

interface PASMomLike {
    function beamState() external view returns (address);
    function timelock() external view returns (address);
    function setAuthority(address) external;
}

library PASInit {
    uint256 constant internal WAD = 10**18;

    enum Role {
        _UNSET,   // 0 (unused)
        DELAYED,  // 1
        IMMEDIATE // 2
    }

    function init(
        PASInstance memory pasInstance,
        uint256            minDelay,
        address            coreCouncil,
        address[]   memory cancellers,
        address[]   memory pausers
    ) internal {
        BeamStateLike    beamState    = BeamStateLike(pasInstance.beamState);
        ConfiguratorLike configurator = ConfiguratorLike(pasInstance.configurator);
        TimelockLike     timelock     = TimelockLike(pasInstance.timelock);

        // --- Sanity checks ---

        require(configurator.beamState() == address(beamState), "PASInit/configurator-beamState-mismatch");
        require(timelock.getMinDelay()   == minDelay,           "PASInit/timelock-minDelay-mismatch");

        // --- Configure BeamState ---

        // Define Beam actions that are accessed through timelock (DELAYED) and directly (IMMEDIATE)
        beamState.setRoleAction(uint8(Role.DELAYED),   BeamStateLike.start.selector,                    true);
        beamState.setRoleAction(uint8(Role.DELAYED),   BeamStateLike.setHop.selector,                   true);
        beamState.setRoleAction(uint8(Role.DELAYED),   BeamStateLike.setMaxChange.selector,             true);
        beamState.setRoleAction(uint8(Role.DELAYED),   BeamStateLike.addRateLimits.selector,            true);
        beamState.setRoleAction(uint8(Role.DELAYED),   BeamStateLike.addController.selector,            true);
        beamState.setRoleAction(uint8(Role.DELAYED),   BeamStateLike.addCBeam.selector,                 true);
        beamState.setRoleAction(uint8(Role.DELAYED),   BeamStateLike.addInitRateLimits.selector,        true);
        beamState.setRoleAction(uint8(Role.DELAYED),   BeamStateLike.addInitControllerActions.selector, true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.stop.selector,                     true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.delRateLimits.selector,            true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.delController.selector,            true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.delCBeam.selector,                 true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.setCBeamForRateLimits.selector,    true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.unsetCBeamForRateLimits.selector,  true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.setCBeamForController.selector,    true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.unsetCBeamForController.selector,  true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.delInitRateLimits.selector,        true);
        beamState.setRoleAction(uint8(Role.IMMEDIATE), BeamStateLike.delInitControllerActions.selector, true);

        // Set timelock as the user with DELAYED role and coreCouncil with IMMEDIATE role
        beamState.setUserRole(address(timelock), uint8(Role.DELAYED),   true);
        beamState.setUserRole(coreCouncil,       uint8(Role.IMMEDIATE), true);

        // --- Configure Timelock ---

        // Grant the coreCouncil as the proposer in the timelock directly
        // Grant cancellers and pausers in timelock with their respective roles
        timelock.grantRole(timelock.PROPOSER_ROLE(),  coreCouncil);
        timelock.grantRole(timelock.CANCELLER_ROLE(), coreCouncil);
        for (uint256 i = 0; i < cancellers.length; ++i) {
            timelock.grantRole(timelock.CANCELLER_ROLE(), cancellers[i]);
        }
        for (uint256 i = 0; i < pausers.length; ++i) {
            timelock.grantRole(timelock.PAUSER_ROLE(), pausers[i]);
        }
    }

    function addCoreToChainlog(
        DssInstance memory dss,
        PASInstance memory pasInstance
    ) internal {
        dss.chainlog.setAddress("PAS_STATE",        pasInstance.beamState);
        dss.chainlog.setAddress("PAS_CONFIGURATOR", pasInstance.configurator);
        dss.chainlog.setAddress("PAS_TIMELOCK",     pasInstance.timelock);
    }

    function initMom(
        DssInstance memory dss,
        PASInstance memory pasInstance,
        address mom_
    ) internal {
        BeamStateLike beamState = BeamStateLike(pasInstance.beamState);
        TimelockLike  timelock  = TimelockLike(pasInstance.timelock);
        PASMomLike    mom       = PASMomLike(mom_);

        // --- Sanity checks ---

        require(mom.beamState() == address(beamState), "PASInit/mom-beamState-mismatch");
        require(mom.timelock()  == address(timelock),  "PASInit/mom-timelock-mismatch");

        // --- Set permissions ---

        // Rely Mom on BeamState to call stop()
        beamState.rely(address(mom));
        // Give Mom the PAUSER_ROLE to call pause() on Timelock
        timelock.grantRole(timelock.PAUSER_ROLE(), address(mom));
        // Set Mom's authority to MCD_ADM
        mom.setAuthority(dss.chainlog.getAddress("MCD_ADM"));

        // --- Chainlog ---

        dss.chainlog.setAddress("PAS_MOM", address(mom));
    }

    function initTimelockWrapper(
        PASInstance memory pasInstance,
        address timelockWrapper_,
        address coreCouncil
    ) internal {
        TimelockLike        timelock        = TimelockLike(pasInstance.timelock);
        TimelockWrapperLike timelockWrapper = TimelockWrapperLike(timelockWrapper_);

        // --- Sanity checks ---

        require(timelockWrapper.timelock()  == pasInstance.timelock,  "PASInit/wrapper-timelock-mismatch");
        require(timelockWrapper.beamState() == pasInstance.beamState, "PASInit/wrapper-beamState-mismatch");

        // --- Set permissions ---

        // Grant the coreCouncil as the proposer through the wrapper
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(timelockWrapper));
        timelockWrapper.kiss(coreCouncil);
    }
}
