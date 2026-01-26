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

import { ScriptTools } from "dss-test/ScriptTools.sol";
import { PASInstance } from "./PASInstance.sol";
import { BeamState } from "src/BeamState.sol";
import { Configurator } from "src/Configurator.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { TimelockWrapper } from "src/timelock/TimelockWrapper.sol";
import { PASMom } from "src/PASMom.sol";

library PASDeploy {

    function deploy(
        address deployer,
        address owner,
        uint256 minDelay
    ) internal returns (PASInstance memory pasInstance) {
        pasInstance.beamState = address(new BeamState());
        pasInstance.configurator = address(new Configurator(pasInstance.beamState));
        pasInstance.timelock = address(new Timelock(
            minDelay,
            owner
        ));
        ScriptTools.switchOwner(pasInstance.beamState, deployer, owner);
    }

    function deployMom(
        address owner,
        address beamState,
        address timelock
    ) internal returns (address mom) {
        mom = address(new PASMom(
            beamState,
            timelock
        ));
        PASMom(mom).setOwner(owner);
    }

    function deployTimelockWrapper(
        address deployer,
        address owner,
        address timelock,
        address beamState
    ) internal returns (address timelockWrapper) {
        timelockWrapper = address(new TimelockWrapper(
            timelock,
            beamState
        ));
        ScriptTools.switchOwner(timelockWrapper, deployer, owner);
    }
}
