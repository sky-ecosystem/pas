// SPDX-FileCopyrightText: © 2025 Dai Foundation <www.daifoundation.org>
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

pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// PAU governance imports
import {BeamState} from "../src/BeamState.sol";
import {Configurator} from "../src/Configurator.sol";
import {Timelock} from "../src/timelock/Timelock.sol";
import {TimelockWrapper, RateLimitConfig} from "../src/timelock/TimelockWrapper.sol";

// Allocator deploy imports
import {AllocatorDeploy} from "dss-allocator/deploy/AllocatorDeploy.sol";
import {AllocatorInit, AllocatorIlkConfig} from "dss-allocator/deploy/AllocatorInit.sol";
import {AllocatorSharedInstance, AllocatorIlkInstance} from "dss-allocator/deploy/AllocatorInstances.sol";

// ALM Controller deploy imports
import {MainnetControllerDeploy} from "spark-alm-controller/deploy/ControllerDeploy.sol";
import {MainnetControllerInit} from "spark-alm-controller/deploy/MainnetControllerInit.sol";
import {ControllerInstance} from "spark-alm-controller/deploy/ControllerInstance.sol";
import {MainnetController} from "spark-alm-controller/src/MainnetController.sol";
import {ALMProxy} from "spark-alm-controller/src/ALMProxy.sol";
import {RateLimits} from "spark-alm-controller/src/RateLimits.sol";

// dss-test imports
import {DssInstance, MCD} from "dss-test/MCD.sol";

// ============================================================================
// Additional Interface Definitions
// ============================================================================

interface IVault {
    function buffer() external view returns (address);
    function rely(address) external;
    function deny(address) external;
    function wards(address) external view returns (uint256);
}

interface IBuffer {
    function approve(address token, address spender, uint256 amount) external;
}

interface IPSM {
    function kiss(address) external;
    function diss(address) external;
    function bud(address) external view returns (uint256);
}

interface IRolesLike {
    function setIlkAdmin(bytes32 ilk, address admin) external;
    function setUserRole(bytes32 ilk, address who, uint8 role, bool enabled) external;
    function ilkAdmins(bytes32 ilk) external view returns (address);
}

// ============================================================================
// Main Test Contract
// ============================================================================

/// @title NewPrimeInitializationIntegrationTest
/// @notice Test for deploying and initializing a completely NEW Prime from scratch
/// @dev Uses mainnet fork and demonstrates:
///      1. Deploying new allocator (vault + buffer) via AllocatorDeploy
///      2. Deploying new ALM contracts via MainnetControllerDeploy
///      3. Initializing ALM via MainnetControllerInit
///      4. Setting up PAS governance (BeamState, Configurator, Timelock, Wrapper)
///      5. Configuring Prime via PAS
contract NewPrimeInitializationIntegrationTest is Test {

    // ========================================================================
    // Constants - Sky Protocol Addresses (from chainlog)
    // ========================================================================

    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
    address constant USDS_JOIN = 0x3C0f895007CA717Aa01c8693e59DF1e8C3777FEB;
    address constant PSM = 0xf6e72Db5454dd049d0788e411b06CfAF16853042; // MCD_LITE_PSM_USDC_A
    address constant PAUSE_PROXY = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB; // MCD_PAUSE_PROXY
    address constant CCTP_TOKEN_MESSENGER = 0xBd3fa81B58Ba92a82136038B25aDec7066af3155;
    address constant ILK_REGISTRY = 0x5a464C28D19848f44199D003BeF5ecc87d090F87;

    // Existing Spark Allocation System (we use shared components)
    address constant ALLOCATOR_ROLES = 0x9A865A710399cea85dbD9144b7a09C889e94E803;
    address constant ALLOCATOR_REGISTRY = 0xCdCFA95343DA7821fdD01dc4d0AeDA958051bB3B;
    address constant PIP_ALLOCATOR = 0xc7B91C401C02B73CBdF424dFaaa60950d5040dB7;

    // Spark Governance
    address constant SPARK_PROXY = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;

    // ========================================================================
    // Constants - CCTP Domain IDs
    // ========================================================================

    uint32 constant DOMAIN_ID_CIRCLE_ETHEREUM = 0;
    uint32 constant DOMAIN_ID_CIRCLE_BASE = 6;

    // ========================================================================
    // Constants - Rate Limit Keys
    // ========================================================================

    bytes32 constant LIMIT_USDS_MINT = keccak256("LIMIT_USDS_MINT");
    bytes32 constant LIMIT_USDS_TO_USDC = keccak256("LIMIT_USDS_TO_USDC");
    bytes32 constant LIMIT_USDC_TO_CCTP = keccak256("LIMIT_USDC_TO_CCTP");
    bytes32 constant LIMIT_USDC_TO_DOMAIN = keccak256("LIMIT_USDC_TO_DOMAIN");

    // ========================================================================
    // Constants - Test Parameters
    // ========================================================================

    uint256 constant TIMELOCK_DELAY = 14 days;
    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;
    uint256 constant HOP_DEFAULT = 18 hours;
    uint256 constant MAX_CHANGE_DEFAULT = 1.2e18; // 20% max increase

    // New Prime ILK
    bytes32 constant NEW_PRIME_ILK = "ALLOCATOR-NEW-PRIME-A";

    // ========================================================================
    // Constants - BeamState Roles (see ROLES.md)
    // ========================================================================

    uint8 constant ROLE_CORE_COUNCIL_TIMELOCKED = 0;
    uint8 constant ROLE_CORE_COUNCIL_DIRECT = 1;

    // ========================================================================
    // State Variables - Tokens
    // ========================================================================

    IERC20 usds;
    IERC20 usdc;

    // ========================================================================
    // State Variables - DSS Instance
    // ========================================================================

    DssInstance dss;

    // ========================================================================
    // State Variables - Allocator (NEW - deployed by this test)
    // ========================================================================

    AllocatorSharedInstance allocatorShared;
    AllocatorIlkInstance allocatorIlk;

    // ========================================================================
    // State Variables - ALM Contracts (NEW - deployed by this test)
    // ========================================================================

    ControllerInstance controllerInstance;
    MainnetController controller;
    ALMProxy almProxy;
    RateLimits rateLimits;

    // ========================================================================
    // State Variables - PAU Governance Layer
    // ========================================================================

    BeamState beamState;
    Configurator configurator;
    Timelock timelock;
    TimelockWrapper wrapper;

    // ========================================================================
    // State Variables - Test Actors
    // ========================================================================

    address coreCouncil;
    address govOps;
    address relayer;
    address freezer;
    address foreignPrime;
    address newPrimeProxy; // The "Spark Proxy" for the new Prime

    // ========================================================================
    // State Variables - Rate Limit Parameters (stored to avoid stack issues)
    // ========================================================================

    uint256 usdsMintMax;
    uint256 usdsMintSlope;
    uint256 usdsToUsdcMax;
    uint256 usdsToUsdcSlope;
    uint256 cctpMax;
    uint256 cctpSlope;
    bytes32 domainKeyBase;

    // ========================================================================
    // Setup
    // ========================================================================

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpcUrl);

        // Initialize DSS instance from chainlog
        dss = MCD.loadFromChainlog(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

        // Initialize tokens
        usds = IERC20(USDS);
        usdc = IERC20(USDC);

        // Initialize test actors
        coreCouncil = makeAddr("coreCouncil");
        govOps = makeAddr("govOps");
        relayer = makeAddr("relayer");
        freezer = makeAddr("freezer");
        foreignPrime = makeAddr("foreignPrime");
        newPrimeProxy = makeAddr("newPrimeProxy"); // Admin for the new Prime's ALM contracts

        // Use existing shared allocator components
        allocatorShared = AllocatorSharedInstance({
            oracle: PIP_ALLOCATOR,
            roles: ALLOCATOR_ROLES,
            registry: ALLOCATOR_REGISTRY
        });

        // Label addresses
        vm.label(USDS, "USDS");
        vm.label(USDC, "USDC");
        vm.label(PSM, "PSM");
        vm.label(SPARK_PROXY, "SparkProxy");
        vm.label(PAUSE_PROXY, "PauseProxy");
        vm.label(newPrimeProxy, "NewPrimeProxy");
    }

    // ========================================================================
    // Helper Functions
    // ========================================================================

    function _makeUint32Key(bytes32 baseKey, uint32 value) internal pure returns (bytes32) {
        return keccak256(abi.encode(baseKey, value));
    }

    function _deployAllocator() internal {
        // Deploy new vault and buffer for the new Prime
        // Note: deployer is address(this), owner is PAUSE_PROXY
        vm.startPrank(PAUSE_PROXY);
        allocatorIlk = AllocatorDeploy.deployIlk({
            deployer: PAUSE_PROXY,
            owner: PAUSE_PROXY,
            roles: ALLOCATOR_ROLES,
            ilk: NEW_PRIME_ILK,
            usdsJoin: USDS_JOIN
        });
        vm.stopPrank();

        vm.label(allocatorIlk.vault, "NewVault");
        vm.label(allocatorIlk.buffer, "NewBuffer");
    }

    function _initAllocator() internal {
        // Initialize the new allocator ilk in the MCD system
        AllocatorIlkConfig memory cfg = AllocatorIlkConfig({
            ilk: NEW_PRIME_ILK,
            duty: RAY, // 0% stability fee
            gap: 100_000_000 * WAD, // 100M gap for auto-line
            maxLine: 1_000_000_000 * WAD, // 1B max line
            ttl: 24 hours,
            allocatorProxy: newPrimeProxy,
            ilkRegistry: ILK_REGISTRY
        });

        vm.startPrank(PAUSE_PROXY);
        AllocatorInit.initIlk(dss, allocatorShared, allocatorIlk, cfg);

        // Set initial debt ceiling (line is in RAD = WAD * RAY)
        // AllocatorInit sets up auto-line but starts with line=0
        uint256 initialLine = 100_000_000 * WAD * RAY; // 100M RAD
        dss.vat.file(NEW_PRIME_ILK, "line", initialLine);
        vm.stopPrank();
    }

    function _deployALMContracts() internal {
        // Deploy new ALM contracts (ALMProxy, RateLimits, MainnetController)
        // with newPrimeProxy as admin
        controllerInstance = MainnetControllerDeploy.deployFull({
            admin: newPrimeProxy,
            vault: allocatorIlk.vault,
            psm: PSM,
            daiUsds: DAI_USDS,
            cctp: CCTP_TOKEN_MESSENGER
        });

        controller = MainnetController(controllerInstance.controller);
        almProxy = ALMProxy(payable(controllerInstance.almProxy));
        rateLimits = RateLimits(controllerInstance.rateLimits);

        vm.label(address(controller), "NewMainnetController");
        vm.label(address(almProxy), "NewALMProxy");
        vm.label(address(rateLimits), "NewRateLimits");
    }

    function _initALMSystem() internal {
        // PAUSE_PROXY authorizes ALMProxy on PSM (for no-fee swaps)
        vm.startPrank(PAUSE_PROXY);
        MainnetControllerInit.pauseProxyInitAlmSystem(PSM, address(almProxy));
        vm.stopPrank();

        // newPrimeProxy initializes the ALM controller
        // We use a minimal init - just freezer, relayers/mintRecipients via PAS later
        MainnetControllerInit.ConfigAddressParams memory configAddresses = MainnetControllerInit.ConfigAddressParams({
            freezer: freezer,
            relayers: new address[](0), // Will add via PAS
            oldController: address(0)
        });

        MainnetControllerInit.CheckAddressParams memory checkAddresses = MainnetControllerInit.CheckAddressParams({
            admin: newPrimeProxy,
            proxy: address(almProxy),
            rateLimits: address(rateLimits),
            vault: allocatorIlk.vault,
            psm: PSM,
            daiUsds: DAI_USDS,
            cctp: CCTP_TOKEN_MESSENGER
        });

        MainnetControllerInit.MintRecipient[] memory mintRecipients = new MainnetControllerInit.MintRecipient[](0);
        MainnetControllerInit.LayerZeroRecipient[] memory layerZeroRecipients = new MainnetControllerInit.LayerZeroRecipient[](0);
        MainnetControllerInit.MaxSlippageParams[] memory maxSlippageParams = new MainnetControllerInit.MaxSlippageParams[](0);

        vm.startPrank(newPrimeProxy);
        MainnetControllerInit.initAlmSystem(
            allocatorIlk.vault,
            USDS,
            controllerInstance,
            configAddresses,
            checkAddresses,
            mintRecipients,
            layerZeroRecipients,
            maxSlippageParams
        );
        vm.stopPrank();
    }

    function _deployPAUGovernance() internal {
        // Deploy BeamState
        beamState = new BeamState();

        // Deploy Configurator
        configurator = new Configurator(address(beamState));

        // Deploy Timelock with PAUSE_PROXY as admin
        address[] memory proposers = new address[](1);
        proposers[0] = coreCouncil;
        address[] memory cancellers = new address[](1);
        cancellers[0] = coreCouncil;
        address[] memory pausers = new address[](1);
        pausers[0] = PAUSE_PROXY;

        timelock = new Timelock(TIMELOCK_DELAY, PAUSE_PROXY, proposers, cancellers, pausers);

        // Deploy TimelockWrapper
        wrapper = new TimelockWrapper(
            address(timelock),
            address(beamState)
        );

        // Grant wrapper PROPOSER_ROLE on timelock
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(PAUSE_PROXY);
        timelock.grantRole(proposerRole, address(wrapper));

        // Configure BeamState: add PAUSE_PROXY and timelock as wards
        beamState.rely(PAUSE_PROXY);
        beamState.rely(address(timelock));

        // Configure wrapper: add PAUSE_PROXY as ward and coreCouncil as bud
        wrapper.rely(PAUSE_PROXY);
        vm.startPrank(PAUSE_PROXY);
        wrapper.kiss(coreCouncil);
        vm.stopPrank();

        // Deny test contract
        beamState.deny(address(this));
        wrapper.deny(address(this));

        // Label deployed contracts
        vm.label(address(beamState), "BeamState");
        vm.label(address(configurator), "Configurator");
        vm.label(address(timelock), "Timelock");
        vm.label(address(wrapper), "TimelockWrapper");
    }

    function _setupBeamStateRoles() internal {
        vm.startPrank(PAUSE_PROXY);

        // Role 0: Core Council Timelocked functions
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.start.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.setHop.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.setMaxChange.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.addRateLimits.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.addController.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.addCBeam.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.addInitRateLimits.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, bytes4(keccak256("addInitControllerActions(bytes,address)")), true);

        // Role 1: Core Council Direct functions
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.stop.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.delRateLimits.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.delController.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.delCBeam.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.setCBeamForRateLimits.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.unsetCBeamForRateLimits.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.setCBeamForController.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.unsetCBeamForController.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.delInitRateLimits.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_DIRECT, BeamState.delInitControllerActions.selector, true);

        // Grant roles
        beamState.setUserRole(coreCouncil, ROLE_CORE_COUNCIL_DIRECT, true);
        beamState.setUserRole(address(timelock), ROLE_CORE_COUNCIL_TIMELOCKED, true);

        vm.stopPrank();
    }

    function _scheduleAndExecute(
        address target,
        bytes memory data,
        bytes32 salt
    ) internal {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;

        vm.prank(coreCouncil);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _executeScheduledBatch(
        address target,
        bytes memory payload,
        bytes32 salt
    ) internal {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    // ========================================================================
    // Test: Complete New Prime Deployment and Initialization
    // ========================================================================

    /// @notice Tests deploying and initializing a completely NEW Prime from scratch
    /// @dev Phases:
    ///      1. Deploy new Allocator (vault + buffer) via AllocatorDeploy
    ///      2. Initialize Allocator ilk via AllocatorInit
    ///      3. Deploy new ALM contracts via MainnetControllerDeploy
    ///      4. Initialize ALM via MainnetControllerInit
    ///      5. Deploy PAU Governance Layer
    ///      6. Configure BeamState defaults
    ///      7. Add rate limit and controller action inits
    ///      8. Register contracts and cBeams
    ///      9. Grant Configurator admin roles
    ///      10. Configure Prime via Configurator
    ///      11-13. Execute operations
    function test_newPrimeDeploymentAndInitialization() public {
        // ====================================================================
        // PHASE 1: Deploy new Allocator
        // ====================================================================

        _deployAllocator();

        emit log("=== Phase 1: New Allocator Deployed ===");
        emit log_named_address("New Vault", allocatorIlk.vault);
        emit log_named_address("New Buffer", allocatorIlk.buffer);

        // ====================================================================
        // PHASE 2: Initialize Allocator ilk in MCD
        // ====================================================================

        _initAllocator();

        emit log("=== Phase 2: Allocator ilk initialized in MCD ===");

        // Verify vault owner is newPrimeProxy
        assertEq(IVault(allocatorIlk.vault).wards(newPrimeProxy), 1, "newPrimeProxy should be vault ward");

        // ====================================================================
        // PHASE 3: Deploy ALM Contracts
        // ====================================================================

        _deployALMContracts();

        emit log("=== Phase 3: ALM Contracts Deployed ===");
        emit log_named_address("MainnetController", address(controller));
        emit log_named_address("ALMProxy", address(almProxy));
        emit log_named_address("RateLimits", address(rateLimits));

        // Verify admin roles
        assertTrue(almProxy.hasRole(almProxy.DEFAULT_ADMIN_ROLE(), newPrimeProxy), "newPrimeProxy should be ALMProxy admin");
        assertTrue(rateLimits.hasRole(rateLimits.DEFAULT_ADMIN_ROLE(), newPrimeProxy), "newPrimeProxy should be RateLimits admin");
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), newPrimeProxy), "newPrimeProxy should be Controller admin");

        // ====================================================================
        // PHASE 4: Initialize ALM System
        // ====================================================================

        _initALMSystem();

        emit log("=== Phase 4: ALM System Initialized ===");

        // Verify PSM authorization
        assertEq(IPSM(PSM).bud(address(almProxy)), 1, "ALMProxy should be authorized on PSM");

        // Verify vault authorization
        assertEq(IVault(allocatorIlk.vault).wards(address(almProxy)), 1, "ALMProxy should be vault ward");

        // ====================================================================
        // PHASE 5: Deploy PAU Governance Layer
        // ====================================================================

        _deployPAUGovernance();
        _setupBeamStateRoles();

        emit log("=== Phase 5: PAU Governance Layer Deployed ===");
        emit log_named_address("BeamState", address(beamState));
        emit log_named_address("Configurator", address(configurator));
        emit log_named_address("Timelock", address(timelock));

        // ====================================================================
        // PHASE 6: Configure BeamState defaults (via wrapper)
        // ====================================================================

        vm.prank(coreCouncil);
        wrapper.setHop(address(0), HOP_DEFAULT, bytes32(0), keccak256("setHop"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.setHop, (address(0), HOP_DEFAULT)),
            keccak256("setHop")
        );

        vm.prank(coreCouncil);
        wrapper.setMaxChange(address(0), MAX_CHANGE_DEFAULT, bytes32(0), keccak256("setMaxChange"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.setMaxChange, (address(0), MAX_CHANGE_DEFAULT)),
            keccak256("setMaxChange")
        );

        emit log("=== Phase 6: BeamState defaults configured ===");

        // ====================================================================
        // PHASE 7: Add Rate Limit and Controller Action Inits
        // ====================================================================

        usdsMintMax = 10_000_000e18;
        usdsMintSlope = uint256(5_000_000e18) / 1 days;
        usdsToUsdcMax = 10_000_000e6;
        usdsToUsdcSlope = uint256(5_000_000e6) / 1 days;
        cctpMax = 5_000_000e6;
        cctpSlope = uint256(2_500_000e6) / 1 days;
        domainKeyBase = _makeUint32Key(LIMIT_USDC_TO_DOMAIN, DOMAIN_ID_CIRCLE_BASE);

        RateLimitConfig[] memory configs = new RateLimitConfig[](4);
        configs[0] = RateLimitConfig(LIMIT_USDS_MINT, address(0), usdsMintMax, usdsMintSlope);
        configs[1] = RateLimitConfig(LIMIT_USDS_TO_USDC, address(0), usdsToUsdcMax, usdsToUsdcSlope);
        configs[2] = RateLimitConfig(LIMIT_USDC_TO_CCTP, address(0), cctpMax, cctpSlope);
        configs[3] = RateLimitConfig(domainKeyBase, address(0), cctpMax, cctpSlope);

        vm.prank(coreCouncil);
        wrapper.batchAddInitRateLimits(configs, bytes32(0), keccak256("batchAddInitRateLimits"), TIMELOCK_DELAY);

        {
            address[] memory targets = new address[](4);
            uint256[] memory values = new uint256[](4);
            bytes[] memory payloads = new bytes[](4);
            for (uint256 i = 0; i < 4; i++) {
                targets[i] = address(beamState);
                values[i] = 0;
                payloads[i] = abi.encodeCall(BeamState.addInitRateLimits, (configs[i].key, configs[i].rateLimits_, configs[i].maxAmount, configs[i].slope));
            }
            vm.warp(block.timestamp + TIMELOCK_DELAY);
            timelock.executeBatch(targets, values, payloads, bytes32(0), keccak256("batchAddInitRateLimits"));
        }

        // Add controller action inits for setMintRecipient and grantRole(RELAYER)
        bytes memory setMintRecipientCall = abi.encodeWithSelector(
            MainnetController.setMintRecipient.selector,
            DOMAIN_ID_CIRCLE_BASE,
            bytes32(uint256(uint160(foreignPrime)))
        );

        vm.prank(coreCouncil);
        wrapper.setMintRecipient(
            DOMAIN_ID_CIRCLE_BASE,
            bytes32(uint256(uint160(foreignPrime))),
            address(0),
            bytes32(0),
            keccak256("setMintRecipient"),
            TIMELOCK_DELAY
        );
        _executeScheduledBatch(
            address(beamState),
            abi.encodeWithSelector(
                bytes4(keccak256("addInitControllerActions(bytes,address)")),
                setMintRecipientCall,
                address(0)
            ),
            keccak256("setMintRecipient")
        );

        bytes32 relayerRole = controller.RELAYER();
        bytes memory grantRelayerCall = abi.encodeWithSelector(
            bytes4(keccak256("grantRole(bytes32,address)")),
            relayerRole,
            relayer
        );

        // Add grantRole(RELAYER, relayer) action via wrapper.grantRole
        vm.prank(coreCouncil);
        wrapper.grantRole(address(controller), relayerRole, relayer, bytes32(0), keccak256("grantRelayer"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeWithSelector(
                bytes4(keccak256("addInitControllerActions(bytes,address)")),
                grantRelayerCall,
                address(controller)
            ),
            keccak256("grantRelayer")
        );

        emit log("=== Phase 7: Rate limit and controller action inits added ===");

        // ====================================================================
        // PHASE 8: Register contracts and cBeams
        // ====================================================================

        // Add govOps as cBeam
        vm.prank(coreCouncil);
        wrapper.addCBeam(govOps, bytes32(0), keccak256("addCBeam_govOps"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.addCBeam, (govOps)),
            keccak256("addCBeam_govOps")
        );

        // Whitelist RateLimits via wrapper.addRateLimits
        vm.prank(coreCouncil);
        wrapper.addRateLimits(address(rateLimits), bytes32(0), keccak256("addRateLimits"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.addRateLimits, (address(rateLimits))),
            keccak256("addRateLimits")
        );

        // Whitelist Controller via wrapper.addController
        vm.prank(coreCouncil);
        wrapper.addController(address(controller), bytes32(0), keccak256("addController"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.addController, (address(controller))),
            keccak256("addController")
        );

        // Associate govOps with contracts (direct)
        vm.prank(coreCouncil);
        beamState.setCBeamForRateLimits(address(rateLimits), govOps);

        vm.prank(coreCouncil);
        beamState.setCBeamForController(address(controller), govOps);

        emit log("=== Phase 8: Contracts and cBeams registered ===");

        // ====================================================================
        // PHASE 9: Grant Configurator admin roles
        // ====================================================================

        vm.startPrank(newPrimeProxy);
        rateLimits.grantRole(rateLimits.DEFAULT_ADMIN_ROLE(), address(configurator));
        controller.grantRole(controller.DEFAULT_ADMIN_ROLE(), address(configurator));
        vm.stopPrank();

        emit log("=== Phase 9: Configurator granted admin roles ===");

        // ====================================================================
        // PHASE 10: Configure Prime via Configurator (GovOps as cBeam)
        // ====================================================================

        vm.startPrank(govOps);

        // Set rate limits
        configurator.setRateLimit(address(rateLimits), LIMIT_USDS_MINT, usdsMintMax, usdsMintSlope);
        configurator.setRateLimit(address(rateLimits), LIMIT_USDS_TO_USDC, usdsToUsdcMax, usdsToUsdcSlope);
        configurator.setRateLimit(address(rateLimits), LIMIT_USDC_TO_CCTP, cctpMax, cctpSlope);
        configurator.setRateLimit(address(rateLimits), domainKeyBase, cctpMax, cctpSlope);


        vm.warp(block.timestamp + 1 days); // give time for the new limits to fill -- in the future this might be changed in Configurator.sol so that a newly set limit is always filled immediately


        // Set mint recipient via controller action
        configurator.callControllerAction(address(controller), setMintRecipientCall);

        // Grant relayer role via controller action
        configurator.callControllerAction(address(controller), grantRelayerCall);

        vm.stopPrank();

        // Verify configuration
        assertTrue(controller.hasRole(relayerRole, relayer), "Relayer should have RELAYER role");
        assertEq(
            controller.mintRecipients(DOMAIN_ID_CIRCLE_BASE),
            bytes32(uint256(uint160(foreignPrime))),
            "Mint recipient should be set for Base"
        );

        emit log("=== Phase 10: Prime configured via Configurator ===");

        // ====================================================================
        // PHASE 11-13: Execute Operations
        // ====================================================================

        _executePhase11_MintUSDS();
        _executePhase12_SwapUSDSToUSDC();
        _executePhase13_TransferCCTP();

        // ====================================================================
        // Summary
        // ====================================================================

        emit log("=== New Prime Deployment and Initialization Complete ===");
        emit log_named_bytes32("ILK", NEW_PRIME_ILK);
        emit log_named_address("Vault", allocatorIlk.vault);
        emit log_named_address("Buffer", allocatorIlk.buffer);
        emit log_named_address("MainnetController", address(controller));
        emit log_named_address("ALMProxy", address(almProxy));
        emit log_named_address("RateLimits", address(rateLimits));
        emit log_named_address("Relayer", relayer);
        emit log_named_uint("Final ALM Proxy USDS balance", usds.balanceOf(address(almProxy)));
        emit log_named_uint("Final ALM Proxy USDC balance", usdc.balanceOf(address(almProxy)));
    }

    function _executePhase11_MintUSDS() internal {
        uint256 mintAmount = 1_000_000e18;

        uint256 proxyUsdsBalanceBefore = usds.balanceOf(address(almProxy));
        uint256 rateLimitBefore = rateLimits.getCurrentRateLimit(LIMIT_USDS_MINT);

        vm.prank(relayer);
        controller.mintUSDS(mintAmount);

        uint256 proxyUsdsBalanceAfter = usds.balanceOf(address(almProxy));
        uint256 rateLimitAfter = rateLimits.getCurrentRateLimit(LIMIT_USDS_MINT);

        assertEq(
            proxyUsdsBalanceAfter - proxyUsdsBalanceBefore,
            mintAmount,
            "ALM Proxy should have received minted USDS"
        );
        assertEq(
            rateLimitBefore - rateLimitAfter,
            mintAmount,
            "Rate limit should have decreased by mint amount"
        );

        emit log_named_uint("USDS minted", mintAmount);
    }

    function _executePhase12_SwapUSDSToUSDC() internal {
        uint256 swapAmount = 500_000e6;

        uint256 proxyUsdcBalanceBefore = usdc.balanceOf(address(almProxy));
        uint256 swapRateLimitBefore = rateLimits.getCurrentRateLimit(LIMIT_USDS_TO_USDC);

        vm.prank(relayer);
        controller.swapUSDSToUSDC(swapAmount);

        uint256 proxyUsdcBalanceAfter = usdc.balanceOf(address(almProxy));
        uint256 swapRateLimitAfter = rateLimits.getCurrentRateLimit(LIMIT_USDS_TO_USDC);

        assertEq(
            proxyUsdcBalanceAfter - proxyUsdcBalanceBefore,
            swapAmount,
            "ALM Proxy should have received USDC from swap"
        );
        assertEq(
            swapRateLimitBefore - swapRateLimitAfter,
            swapAmount,
            "Swap rate limit should have decreased"
        );

        emit log_named_uint("USDC received from swap", swapAmount);
    }

    function _executePhase13_TransferCCTP() internal {
        uint256 transferAmount = 100_000e6;

        uint256 proxyUsdcBefore = usdc.balanceOf(address(almProxy));
        uint256 cctpLimitBefore = rateLimits.getCurrentRateLimit(LIMIT_USDC_TO_CCTP);
        uint256 domainLimitBefore = rateLimits.getCurrentRateLimit(domainKeyBase);
        uint256 supplyBefore = usdc.totalSupply();

        vm.prank(relayer);
        controller.transferUSDCToCCTP(transferAmount, DOMAIN_ID_CIRCLE_BASE);

        uint256 proxyUsdcAfter = usdc.balanceOf(address(almProxy));
        uint256 cctpLimitAfter = rateLimits.getCurrentRateLimit(LIMIT_USDC_TO_CCTP);
        uint256 domainLimitAfter = rateLimits.getCurrentRateLimit(domainKeyBase);
        uint256 supplyAfter = usdc.totalSupply();

        assertEq(proxyUsdcBefore - proxyUsdcAfter, transferAmount, "ALM Proxy USDC should have decreased");
        assertEq(cctpLimitBefore - cctpLimitAfter, transferAmount, "CCTP rate limit should have decreased");
        assertEq(domainLimitBefore - domainLimitAfter, transferAmount, "Domain rate limit should have decreased");
        assertEq(supplyBefore - supplyAfter, transferAmount, "USDC should have been burned for CCTP transfer");

        emit log_named_uint("USDC transferred via CCTP", transferAmount);
    }
}
