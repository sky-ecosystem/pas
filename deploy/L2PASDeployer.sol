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

import { PASDeploy } from "./PASDeploy.sol";
import { PASInit, InitCBeamConfig, InitRateLimitConfig, InitControllerActionConfig } from "./PASInit.sol";
import { PASInstance } from "./PASInstance.sol";

interface TimelockRolesLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function grantRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;
}

interface BeamStateLike {
    function rely(address) external;
    function deny(address) external;
}

struct L2PASDeployerConfig {
    address admin; // ward of BeamState and default admin role of Timelock

    uint256 minDelay; // minimum delay for timelock
    address coreCouncil; // aBEAM operator
    address[] cancellers; // timelock CANCELLER_ROLE holders
    address[] pausers; // timelock PAUSER_ROLE holders

    uint256 hop; // global fallback minimum cooldown in seconds between rate limits increases, enforced per (RateLimits, key).
    uint256 maxChange; // global WAD-scaled growth multiplier (e.g., 1.2e18 = current value x 1.2)
    address[] rateLimits; // RateLimits contracts the Configurator can update
    address[] controllers; // Controller contracts the Configurator can call
    InitCBeamConfig[] cBeamConfigs; // cBEAM operator configurations

    InitRateLimitConfig[] rateLimitConfigs; // per-key initial rate limits
    InitControllerActionConfig[] controllerActionConfigs; // Controller calldata that cBEAM is allowed to submit

    bool timelockPaused;
}

/// @notice One-time deployer: deploys and initializes a full PAS instance in its constructor,
///         hands ownership over to `cfg.admin` and keeps no permissions over it.
/// @dev    It is only meant to be used on L2s: on Ethereum mainnet, PAS is initialized through
///         a spell instead, which also sets up PASMom and adds the chainlog entries.
contract L2PASDeployer {
    address public immutable beamState;
    address public immutable configurator;
    address public immutable timelock;

    constructor(L2PASDeployerConfig memory cfg) {
        require(cfg.admin != address(0),    "L2PASDeployer/admin-zero-address");
        require(cfg.admin != address(this), "L2PASDeployer/admin-is-deployer");

        PASInstance memory pas = PASDeploy.deploy(address(this), address(this), cfg.minDelay);

        PASInit.init(pas, cfg.minDelay, cfg.coreCouncil, cfg.cancellers, cfg.pausers);

        PASInit.initExtras(pas, cfg.hop, cfg.maxChange, cfg.rateLimits, cfg.controllers, cfg.cBeamConfigs);

        PASInit.initLimitsAndControllerData(pas, cfg.rateLimitConfigs, cfg.controllerActionConfigs);

        if (cfg.timelockPaused) {
            PASInit.pauseTimelock(pas.timelock, address(this));
        }

        BeamStateLike(pas.beamState).rely(cfg.admin);
        BeamStateLike(pas.beamState).deny(address(this));

        bytes32 adminRole = TimelockRolesLike(pas.timelock).DEFAULT_ADMIN_ROLE();
        TimelockRolesLike(pas.timelock).grantRole(adminRole, cfg.admin);
        TimelockRolesLike(pas.timelock).renounceRole(adminRole, address(this));

        beamState    = pas.beamState;
        configurator = pas.configurator;
        timelock     = pas.timelock;
    }
}
