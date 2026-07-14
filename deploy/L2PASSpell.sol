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

import { PASInit } from "./PASInit.sol";
import { PASInstance } from "./PASInstance.sol";

// An L2 spell template for L2GovernanceRelay to initialize PAS contracts on a foreign chain.
// This spell should be viewed as skeleton/sample and can be altered prior to being used
// if further configurations are needed (for example adding more proposers).
contract L2PASSpell {

    address public immutable beamState;
    address public immutable configurator;
    address public immutable timelock;

    constructor(address beamState_, address configurator_, address timelock_) {
        beamState    = beamState_;
        configurator = configurator_;
        timelock     = timelock_;
    }

    function init(
        bool             doInit,       // configure BeamState + coreCouncil (IMMEDIATE path)
        bool             doTimelock,   // configure/activate the Timelock (DELAYED path)
        address          coreCouncil,  // used by both: IMMEDIATE role (`doInit`) + proposer/canceller (`doTimelock`)
        uint256          minDelay,     // only used when `doTimelock`
        address[] memory cancellers,   // only used when `doTimelock`
        address[] memory pausers,      // only used when `doTimelock`
        bool             startPaused   // only used when `doTimelock`
    ) external {
        PASInstance memory pas = PASInstance({
            beamState:    beamState,
            configurator: configurator,
            timelock:     timelock
        });

        if (doInit)     PASInit.init(pas, coreCouncil);
        if (doTimelock) PASInit.initTimelock(pas, minDelay, coreCouncil, cancellers, pausers, address(this), startPaused);
    }
}
