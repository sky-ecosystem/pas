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

import "dss-test/DssTest.sol";
import { MCD, DssInstance } from "dss-test/MCD.sol";

import { AllocatorIlkConfig } from "dss-allocator/deploy/AllocatorInit.sol";

import { MainnetControllerDeploy }  from "spark-alm-controller/deploy/ControllerDeploy.sol";
import { MainnetControllerInit }    from "spark-alm-controller/deploy/MainnetControllerInit.sol";
import { ControllerInstance }       from "spark-alm-controller/deploy/ControllerInstance.sol";
import { MainnetController }        from "spark-alm-controller/src/MainnetController.sol";
import { ALMProxy }                 from "spark-alm-controller/src/ALMProxy.sol";
import { RateLimits }               from "spark-alm-controller/src/RateLimits.sol";
import { RateLimitHelpers }         from "spark-alm-controller/src/RateLimitHelpers.sol";

import { SparkVault }               from "spark-vaults-v2/src/SparkVault.sol";

import { GeneratorIlkInstance, GeneratorPrimeInstance } from "deploy/GeneratorInstance.sol";
import { GeneratorDeploy }          from "deploy/GeneratorDeploy.sol";
import { GeneratorInit, GeneratorIlkConfig, GeneratorPrimeConfig, RateLimitEntry } from "deploy/GeneratorInit.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

contract GeneratorIntegrationTest is DssTest {

    // Mainnet addresses
    address constant SPARK_CONTROLLER = 0xE52d643B27601D4d2BAB2052f30cf936ed413cec;
    address constant SPARK_PROXY      = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;
    address constant SPARK_ALM_PROXY  = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant CHAINLOG         = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;
    address constant USDS_ADDR        = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant PAUSE_PROXY      = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB;
    address constant PSM              = 0xf6e72Db5454dd049d0788e411b06CfAF16853042;
    address constant DAI_USDS         = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
    address constant CCTP             = 0xBd3fa81B58Ba92a82136038B25aDec7066af3155;

    uint256 constant FORK_BLOCK       = 24250000;
    bytes32 constant GEN_ILK          = "ALLOCATOR-GENERATOR-A";
    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);

    DssInstance     dss;

    // Generator ilk
    GeneratorIlkInstance genInst;
    MainnetController    genController;
    ALMProxy             genAlmProxy;
    RateLimits           genRateLimits;

    // Generator prime (SparkVault)
    GeneratorPrimeInstance primeInst;
    SparkVault             sparkVault;

    // Spark existing mainnet controller (for takeFromSparkVault)
    MainnetController sparkController;

    address relayer;

    function setUp() public {
        // Fork mainnet at specified block
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        // Load DssInstance from chainlog
        dss = MCD.loadFromChainlog(CHAINLOG);

        relayer  = makeAddr("relayer");

        // --- Deploy generator ilk ---
        genInst = GeneratorDeploy.deployGeneratorIlk(
            address(this),     // deployer
            GEN_ILK,
            CCTP
        );

        genController = MainnetController(genInst.controller);
        genAlmProxy   = ALMProxy(payable(genInst.almProxy));
        genRateLimits = RateLimits(genInst.rateLimits);

        // --- Deploy SparkVault for the prime ---
        primeInst = GeneratorDeploy.deployPrime(
            "Generator USDS Vault",
            "gUSDSv"
        );
        sparkVault = SparkVault(primeInst.sparkVault);

        // --- Initialize generator ilk ---
        address[] memory relayers = new address[](1);
        relayers[0] = relayer;

        uint256 usdsMaxAmount = 10_000_000e18;
        uint256 usdsSlope     = uint256(1_000_000e18) / 4 hours;

        // Rate limit entries for generator
        RateLimitEntry[] memory rateLimitEntries = new RateLimitEntry[](2);
        rateLimitEntries[0] = RateLimitEntry({
            key:       genController.LIMIT_USDS_MINT(),
            maxAmount: usdsMaxAmount,
            slope:     usdsSlope
        });
        rateLimitEntries[1] = RateLimitEntry({
            key:       RateLimitHelpers.makeAddressKey(
                           genController.LIMIT_4626_DEPOSIT(),
                           primeInst.sparkVault
                       ),
            maxAmount: usdsMaxAmount,
            slope:     usdsSlope
        });

        GeneratorIlkConfig memory genCfg;
        genCfg.allocatorIlkCfg = AllocatorIlkConfig({
            ilk:            GEN_ILK,
            duty:           RAY,                    // 0% stability fee
            maxLine:        100_000_000 * RAD,
            gap:            10_000_000 * RAD,
            ttl:            6 hours,
            allocatorProxy: address(0),             // set by GeneratorInit from chainlog
            ilkRegistry:    IChainlogLike(CHAINLOG).getAddress("ILK_REGISTRY")
        });
        genCfg.configAddresses = MainnetControllerInit.ConfigAddressParams({
            freezer:       address(0),
            relayers:      relayers,
            oldController: address(0)
        });
        genCfg.checkAddresses = MainnetControllerInit.CheckAddressParams({
            admin:      address(0),                 // set by GeneratorInit from chainlog
            proxy:      genInst.almProxy,
            rateLimits: genInst.rateLimits,
            vault:      genInst.allocatorVault,
            psm:        PSM,
            daiUsds:    DAI_USDS,
            cctp:       CCTP
        });
        genCfg.rateLimitEntries   = rateLimitEntries;

        vm.startPrank(PAUSE_PROXY);
        GeneratorInit.init(dss, genInst, genCfg);
        vm.stopPrank();

        // --- Initialize prime (SparkVault) ---
        GeneratorPrimeConfig memory primeCfg = GeneratorPrimeConfig({
            usds:                    USDS_ADDR,
            minVsr:                  RAY,          // 1x (0% APY)
            maxVsr:                  RAY,          // 1x (0% APY)
            depositCap:              100_000_000e18,
            maxExchangeRateShares:   1e18,         // 1:1 exchange rate
            maxExchangeRateAssets:   1e18,
            takerAlmProxy:           SPARK_ALM_PROXY, // Spark's ALM proxy can take from this vault
            chainlogKeyVault:        "GENERATOR_SPARK_VAULT"
        });

        vm.startPrank(PAUSE_PROXY);
        GeneratorInit.initPrime(dss, genInst, primeInst, primeCfg);
        vm.stopPrank();

        // --- Configure Spark's rate limits for takeFromSparkVault ---
        // Spark's controller needs a rate limit for LIMIT_SPARK_VAULT_TAKE on this vault
        sparkController = MainnetController(SPARK_CONTROLLER);

        vm.startPrank(SPARK_PROXY);
        bytes32 sparkVaultTakeKey = RateLimitHelpers.makeAddressKey(
            sparkController.LIMIT_SPARK_VAULT_TAKE(),
            primeInst.sparkVault
        );
        RateLimits(address(sparkController.rateLimits())).setRateLimitData(
            sparkVaultTakeKey,
            usdsMaxAmount,  // maxAmount
            usdsSlope       // slope
        );
        vm.stopPrank();
    }

    // ============================================================================
    // Deployment Tests
    // ============================================================================

    function testDeploymentAddresses() public view {
        assertTrue(genInst.allocatorBuffer != address(0), "allocatorBuffer should be deployed");
        assertTrue(genInst.allocatorVault  != address(0), "allocatorVault should be deployed");
        assertTrue(genInst.almProxy        != address(0), "almProxy should be deployed");
        assertTrue(genInst.controller      != address(0), "controller should be deployed");
        assertTrue(genInst.rateLimits      != address(0), "rateLimits should be deployed");
        assertTrue(primeInst.sparkVault    != address(0), "sparkVault should be deployed");
        assertTrue(primeInst.sparkVaultImpl != address(0), "sparkVaultImpl should be deployed");
    }

    // ============================================================================
    // Permissions Tests
    // ============================================================================

    function testPermissions() public view {
        // Generator controller has CONTROLLER role on ALM proxy
        assertTrue(
            genAlmProxy.hasRole(genAlmProxy.CONTROLLER(), genInst.controller),
            "controller should have CONTROLLER role on almProxy"
        );

        // Generator controller has CONTROLLER role on rate limits
        assertTrue(
            genRateLimits.hasRole(genRateLimits.CONTROLLER(), genInst.controller),
            "controller should have CONTROLLER role on rateLimits"
        );

        // Relayer has RELAYER role on generator controller
        assertTrue(
            genController.hasRole(genController.RELAYER(), relayer),
            "relayer should have RELAYER role on controller"
        );

        // Spark ALM proxy has TAKER_ROLE on SparkVault
        bytes32 TAKER_ROLE = keccak256("TAKER_ROLE");
        assertTrue(
            sparkVault.hasRole(TAKER_ROLE, SPARK_ALM_PROXY),
            "SPARK_ALM_PROXY should have TAKER_ROLE on sparkVault"
        );
    }

    // ============================================================================
    // Full Flow Test
    // ============================================================================

    function testFullFlow() public {
        uint256 amount = 1_000_000e18;

        IERC20 usds = IERC20(USDS_ADDR);

        // --- Step 1: Generator relayer mints USDS ---
        uint256 proxyBalBefore = usds.balanceOf(genInst.almProxy);

        vm.prank(relayer);
        genController.mintUSDS(amount);

        uint256 proxyBalAfterMint = usds.balanceOf(genInst.almProxy);
        assertEq(proxyBalAfterMint - proxyBalBefore, amount, "USDS should be in generator's ALM proxy after mint");

        // --- Step 2: Generator relayer deposits USDS to SparkVault ---
        uint256 vaultBalBefore = usds.balanceOf(primeInst.sparkVault);

        vm.prank(relayer);
        genController.depositERC4626(primeInst.sparkVault, amount);

        uint256 vaultBalAfterDeposit = usds.balanceOf(primeInst.sparkVault);
        assertEq(vaultBalAfterDeposit - vaultBalBefore, amount, "USDS should be in SparkVault after deposit");

        // Proxy should have no USDS left
        assertEq(usds.balanceOf(genInst.almProxy), proxyBalBefore, "generator proxy should have no extra USDS");

        // --- Step 3: Spark relayer takes USDS from SparkVault ---
        // Spark's relayer uses Spark's existing controller to takeFromSparkVault
        address sparkRelayer = makeAddr("sparkRelayer");

        vm.startPrank(SPARK_PROXY);
        sparkController.grantRole(sparkController.RELAYER(), sparkRelayer);
        vm.stopPrank();

        uint256 sparkAlmBalBefore = usds.balanceOf(SPARK_ALM_PROXY);

        vm.prank(sparkRelayer);
        sparkController.takeFromSparkVault(primeInst.sparkVault, amount);

        uint256 sparkAlmBalAfter = usds.balanceOf(SPARK_ALM_PROXY);
        assertEq(sparkAlmBalAfter - sparkAlmBalBefore, amount, "USDS should be in Spark's ALM proxy after take");

        // SparkVault should have no USDS (all taken)
        assertEq(usds.balanceOf(primeInst.sparkVault), vaultBalBefore, "SparkVault should have no extra USDS");
    }
}
