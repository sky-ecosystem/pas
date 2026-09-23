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

import { PASDeploy } from "deploy/PASDeploy.sol";
import { PASInit, InitCBeamConfig, InitRateLimitConfig, InitControllerActionConfig } from "deploy/PASInit.sol";
import { PASInstance } from "deploy/PASInstance.sol";

interface TimelockRolesLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function grantRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;
}

interface BeamStateLike {
    function rely(address) external;
    function deny(address) external;
}

struct PASFactoryConfig {
    address admin; // ward of BeamState and default admin role of Timelock

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

/// @notice The deploy logic has been separated from Factory contract to avoid exceeding the EIP-170 runtime size limit.
contract PASDeployer {
    function deploy(uint256 minDelay) external returns (PASInstance memory pas) {
        pas = PASDeploy.deploy(address(this), msg.sender, minDelay);
    }
}

contract PASFactory {
    
    PASDeployer public immutable deployer;

    event Deployment(address indexed admin, address beamState, address configurator, address timelock);

    constructor() {
        deployer = new PASDeployer();
    }

    function deploy(PASFactoryConfig memory cfg) external returns (PASInstance memory pas) {
        require(cfg.admin != address(0),     "PASFactory/admin-zero-address");
        require(cfg.admin != address(this),  "PASFactory/admin-is-factory");
        require(cfg.hop > 0, "PASFactory/hop-zero");

        pas = deployer.deploy(cfg.minDelay);

        PASInit.init(pas, cfg.minDelay, cfg.coreCouncil, cfg.cancellers, cfg.pausers);

        PASInit.initExtras(pas, cfg.hop, cfg.maxChange, cfg.rateLimits, cfg.controllers, cfg.cBeamConfigs);

        if (cfg.rateLimitConfigs.length > 0 || cfg.controllerActionConfigs.length > 0) {
            PASInit.initLimitsAndControllerData(pas, cfg.rateLimitConfigs, cfg.controllerActionConfigs);
        }

        if (cfg.timelockPaused) {
            PASInit.pauseTimelock(pas.timelock, address(this));
        }

        BeamStateLike(pas.beamState).rely(cfg.admin);
        BeamStateLike(pas.beamState).deny(address(this));

        TimelockRolesLike timelock = TimelockRolesLike(pas.timelock);
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        timelock.grantRole(adminRole, cfg.admin);
        timelock.renounceRole(adminRole, address(this));

        emit Deployment(cfg.admin, pas.beamState, pas.configurator, pas.timelock);
    }
}
