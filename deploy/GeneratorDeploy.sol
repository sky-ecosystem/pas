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

import { AllocatorDeploy }       from "dss-allocator/deploy/AllocatorDeploy.sol";
import { AllocatorIlkInstance }  from "dss-allocator/deploy/AllocatorInstances.sol";
import { MainnetControllerDeploy } from "spark-alm-controller/deploy/ControllerDeploy.sol";
import { ControllerInstance }    from "spark-alm-controller/deploy/ControllerInstance.sol";
import { SparkVault }            from "spark-vaults-v2/src/SparkVault.sol";
import { ERC1967Proxy }          from "openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { GeneratorIlkInstance, GeneratorPrimeInstance } from "./GeneratorInstance.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

library GeneratorDeploy {

    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    function deployGeneratorIlk(
        address deployer,
        bytes32 ilk,
        address cctp
    ) internal returns (GeneratorIlkInstance memory genIlk) {
        address owner = chainlog.getAddress("MCD_PAUSE_PROXY");

        // Deploy AllocatorBuffer + AllocatorVault
        AllocatorIlkInstance memory allocIlk = AllocatorDeploy.deployIlk(
            deployer,
            owner,
            chainlog.getAddress("ALLOCATOR_ROLES"),
            ilk,
            chainlog.getAddress("USDS_JOIN")
        );

        // Deploy ALMProxy + MainnetController + RateLimits
        ControllerInstance memory ctrlInst = MainnetControllerDeploy.deployFull(
            owner,
            allocIlk.vault,
            chainlog.getAddress("MCD_LITE_PSM_USDC_A"),
            chainlog.getAddress("DAI_USDS"),
            cctp
        );

        genIlk.allocatorBuffer = allocIlk.buffer;
        genIlk.allocatorVault  = allocIlk.vault;
        genIlk.almProxy        = ctrlInst.almProxy;
        genIlk.controller      = ctrlInst.controller;
        genIlk.rateLimits      = ctrlInst.rateLimits;
    }

    function deployPrime(
        string memory name,
        string memory symbol
    ) internal returns (GeneratorPrimeInstance memory primeInst) {
        address owner = chainlog.getAddress("MCD_PAUSE_PROXY");
        address usds  = chainlog.getAddress("USDS");

        primeInst.sparkVaultImpl = address(new SparkVault());

        primeInst.sparkVault = address(new ERC1967Proxy(
            primeInst.sparkVaultImpl,
            abi.encodeCall(SparkVault.initialize, (usds, name, symbol, owner))
        ));
    }
}
