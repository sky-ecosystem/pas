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

import { PASDeploy } from "deploy/PASDeploy.sol";
import { PASInit, InitCBeamConfig, InitRateLimitConfig, InitControllerActionConfig } from "deploy/PASInit.sol";
import { PASInstance } from "deploy/PASInstance.sol";

interface TimelockRolesLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function grantRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;
}

struct PASFactoryConfig {
    address owner; // ward of BeamState and default admin role of Timelock

    uint256 minDelay; // minimum delay for timelock
    address coreCouncil; // aBEAM operator
    address[] cancellers; // timelock CANCELLER_ROLE holders
    address[] pausers; // timelock PAUSER_ROLE holders

    uint256 hop; // global minimum delay between cBEAM rate increases
    uint256 maxChange; // global max increase amount between current and new rate limit (WAD)
    address[] rateLimits; // RateLimits the Configurator can update
    address[] controllers; // Controller the Configurator can call
    InitCBeamConfig[] cBeamConfigs; // cBEAM operators configuration

    InitRateLimitConfig[] rateLimitConfigs; // ceilings per-key initial rate limits
    InitControllerActionConfig[] controllerActionConfigs; // Controller calldata that cBEAM is allowed to submit

    bool timelockPaused;
}

contract PASFactory {

    event Deploy(address indexed owner, address beamState, address configurator, address timelock);

    function deploy(PASFactoryConfig memory cfg) external returns (PASInstance memory pas) {
        require(cfg.owner != address(0),     "PASFactory/owner-zero-address");
        require(cfg.owner != address(this),  "PASFactory/owner-is-factory");
        require(cfg.hop > 0, "PASFactory/hop-zero");

        pas = PASDeploy.deploy(address(this), address(this), cfg.minDelay);

        PASInit.init(pas, cfg.minDelay, cfg.coreCouncil, cfg.cancellers, cfg.pausers);

        PASInit.initExtras(pas, cfg.hop, cfg.maxChange, cfg.rateLimits, cfg.controllers, cfg.cBeamConfigs);

        if (cfg.rateLimitConfigs.length > 0 || cfg.controllerActionConfigs.length > 0) {
            PASInit.initLimitsAndControllerData(pas, cfg.rateLimitConfigs, cfg.controllerActionConfigs);
        }

        if (cfg.timelockPaused) {
            PASInit.pauseTimelock(pas.timelock, address(this));
        }

        ScriptTools.switchOwner(pas.beamState, address(this), cfg.owner);

        TimelockRolesLike timelock = TimelockRolesLike(pas.timelock);
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        timelock.grantRole(adminRole, cfg.owner);
        timelock.renounceRole(adminRole, address(this));

        emit Deploy(cfg.owner, pas.beamState, pas.configurator, pas.timelock);
    }
}
