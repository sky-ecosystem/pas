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

import { DssInstance }           from "dss-test/MCD.sol";
import { AllocatorSharedInstance, AllocatorIlkInstance } from "dss-allocator/deploy/AllocatorInstances.sol";
import { AllocatorInit, AllocatorIlkConfig }             from "dss-allocator/deploy/AllocatorInit.sol";
import { MainnetControllerInit }  from "spark-alm-controller/deploy/MainnetControllerInit.sol";
import { ControllerInstance }     from "spark-alm-controller/deploy/ControllerInstance.sol";

import { GeneratorIlkInstance, GeneratorPrimeInstance } from "./GeneratorInstance.sol";

interface AllocatorVaultLike {
    function ilk() external view returns (bytes32);
    function buffer() external view returns (address);
}

interface MainnetControllerLike {
    function vault() external view returns (address);
    function proxy() external view returns (address);
    function rateLimits() external view returns (address);
    function setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external;
}

interface RateLimitsLike {
    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;
}

interface SparkVaultLike {
    function asset() external view returns (address);
    function setVsrBounds(uint256 minVsr, uint256 maxVsr) external;
    function setDepositCap(uint256 newCap) external;
    function grantRole(bytes32 role, address account) external;
}

struct GeneratorIlkConfig {
    AllocatorIlkConfig              allocatorIlkCfg;
    MainnetControllerInit.ConfigAddressParams configAddresses;
    MainnetControllerInit.CheckAddressParams  checkAddresses;
    RateLimitEntry[]                rateLimitEntries;
}

struct RateLimitEntry {
    bytes32 key;
    uint256 maxAmount;
    uint256 slope;
}

struct GeneratorPrimeConfig {
    address usds;
    uint256 minVsr;
    uint256 maxVsr;
    uint256 depositCap;
    uint256 maxExchangeRateShares;  // Shares for max exchange rate calc (e.g. 1e18)
    uint256 maxExchangeRateAssets;  // Assets for max exchange rate calc (e.g. 1e18)
    address takerAlmProxy;          // The prime's ALM proxy that gets TAKER_ROLE
    string  chainlogKeyVault;       // e.g. "SPARK_VAULT_USDS"
}

library GeneratorInit {

    bytes32 constant TAKER_ROLE = keccak256("TAKER_ROLE");

    function init(
        DssInstance              memory dss,
        GeneratorIlkInstance     memory genInst,
        GeneratorIlkConfig       memory cfg
    ) internal {
        // --- Sanity checks ---
        require(
            AllocatorVaultLike(genInst.allocatorVault).ilk() == cfg.allocatorIlkCfg.ilk,
            "GeneratorInit/vault-ilk-mismatch"
        );
        require(
            MainnetControllerLike(genInst.controller).vault() == genInst.allocatorVault,
            "GeneratorInit/controller-vault-mismatch"
        );
        require(
            MainnetControllerLike(genInst.controller).proxy() == genInst.almProxy,
            "GeneratorInit/controller-proxy-mismatch"
        );
        require(
            MainnetControllerLike(genInst.controller).rateLimits() == genInst.rateLimits,
            "GeneratorInit/controller-rateLimits-mismatch"
        );

        // --- 1. Initialize the allocator ilk ---
        address pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");

        AllocatorSharedInstance memory sharedInstance = AllocatorSharedInstance({
            oracle:   dss.chainlog.getAddress("PIP_ALLOCATOR"),
            roles:    dss.chainlog.getAddress("ALLOCATOR_ROLES"),
            registry: dss.chainlog.getAddress("ALLOCATOR_REGISTRY")
        });

        cfg.allocatorIlkCfg.allocatorProxy = pauseProxy;
        cfg.checkAddresses.admin           = pauseProxy;

        AllocatorIlkInstance memory allocIlk = AllocatorIlkInstance({
            owner:  pauseProxy,
            vault:  genInst.allocatorVault,
            buffer: genInst.allocatorBuffer
        });

        AllocatorInit.initIlk(dss, sharedInstance, allocIlk, cfg.allocatorIlkCfg);

        // --- 2. Initialize the ALM system ---
        ControllerInstance memory ctrlInst = ControllerInstance({
            almProxy:   genInst.almProxy,
            controller: genInst.controller,
            rateLimits: genInst.rateLimits
        });

        address usds = dss.chainlog.getAddress("USDS");

        MainnetControllerInit.initAlmSystem(
            genInst.allocatorVault,
            usds,
            ctrlInst,
            cfg.configAddresses,
            cfg.checkAddresses,
            new MainnetControllerInit.MintRecipient[](0), // Assume related functionality for these is unused
            new MainnetControllerInit.LayerZeroRecipient[](0),
            new MainnetControllerInit.MaxSlippageParams[](0)
        );

        // --- 3. Set rate limits ---
        RateLimitsLike rateLimits = RateLimitsLike(genInst.rateLimits);
        for (uint256 i = 0; i < cfg.rateLimitEntries.length; ++i) {
            rateLimits.setRateLimitData(
                cfg.rateLimitEntries[i].key,
                cfg.rateLimitEntries[i].maxAmount,
                cfg.rateLimitEntries[i].slope
            );
        }

        // --- 4. Chainlog ---
        dss.chainlog.setAddress("GENERATOR_ALM_PROXY",   genInst.almProxy);
        dss.chainlog.setAddress("GENERATOR_CONTROLLER",  genInst.controller);
        dss.chainlog.setAddress("GENERATOR_RATE_LIMITS", genInst.rateLimits);
    }

    // TODO: see if need to block others from depositing to the vault
    // TODO: see if need to pre-seed the vault to avoid donation attacks
    function initPrime(
        DssInstance              memory dss,
        GeneratorIlkInstance     memory genInst,
        GeneratorPrimeInstance   memory primeInst,
        GeneratorPrimeConfig     memory cfg
    ) internal {
        SparkVaultLike sparkVault = SparkVaultLike(primeInst.sparkVault);

        // --- Sanity checks ---
        require(sparkVault.asset() == cfg.usds, "GeneratorInit/sparkVault-asset-mismatch");

        // --- Configure SparkVault ---
        sparkVault.setVsrBounds(cfg.minVsr, cfg.maxVsr);
        sparkVault.setDepositCap(cfg.depositCap);

        // --- Set max exchange rate on the controller for the SparkVault ---
        MainnetControllerLike(genInst.controller).setMaxExchangeRate(
            primeInst.sparkVault,
            cfg.maxExchangeRateShares,
            cfg.maxExchangeRateAssets
        );

        // --- Grant TAKER_ROLE to the prime's ALM proxy ---
        sparkVault.grantRole(TAKER_ROLE, cfg.takerAlmProxy);

        // --- Chainlog ---
        dss.chainlog.setAddress(
            bytes32(bytes(cfg.chainlogKeyVault)),
            primeInst.sparkVault
        );
    }
}
