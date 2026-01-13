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

import {BeamState} from "../src/BeamState.sol";
import {Configurator} from "../src/Configurator.sol";
import {Timelock} from "../src/timelock/Timelock.sol";
import {TimelockWrapper, RateLimitConfig} from "../src/timelock/TimelockWrapper.sol";

// ============================================================================
// Interface Definitions for External Contracts
// ============================================================================

interface IMainnetController {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function FREEZER() external view returns (bytes32);
    function RELAYER() external view returns (bytes32);
    function LIMIT_USDS_MINT() external view returns (bytes32);
    function LIMIT_USDS_TO_USDC() external view returns (bytes32);
    function LIMIT_USDC_TO_CCTP() external view returns (bytes32);
    function LIMIT_USDC_TO_DOMAIN() external view returns (bytes32);

    function mintUSDS(uint256 usdsAmount) external;
    function burnUSDS(uint256 usdsAmount) external;
    function swapUSDSToUSDC(uint256 usdcAmount) external;
    function swapUSDCToUSDS(uint256 usdcAmount) external;
    function transferUSDCToCCTP(uint256 usdcAmount, uint32 destinationDomain) external;

    function setMintRecipient(uint32 destinationDomain, bytes32 mintRecipient) external;
    function mintRecipients(uint32) external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    function proxy() external view returns (address);
    function rateLimits() external view returns (address);
}

interface IRateLimits {
    struct RateLimitData {
        uint256 maxAmount;
        uint256 slope;
        uint256 lastAmount;
        uint256 lastUpdated;
    }

    function CONTROLLER() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function getRateLimitData(bytes32 key) external view returns (RateLimitData memory);
    function getCurrentRateLimit(bytes32 key) external view returns (uint256);
    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;
    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope, uint256 lastAmount, uint256 lastUpdated) external;
    function setUnlimitedRateLimitData(bytes32 key) external;

    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IALMProxy {
    function CONTROLLER() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IVault {
    function buffer() external view returns (address);
    function draw(uint256 usdsAmount) external;
    function wipe(uint256 usdsAmount) external;
    function rely(address) external;
    function wards(address) external view returns (uint256);
}

interface IPSM {
    function kiss(address) external;
    function bud(address) external view returns (uint256);
}

interface IBuffer {
    function approve(address token, address spender, uint256 amount) external;
}

// ============================================================================
// Main Test Contract
// ============================================================================

/// @title PrimeInitializationIntegrationTest
/// @notice Comprehensive test for all steps to create and initiate a new Prime
///         that can mint USDS, convert to USDC, and send via CCTP
/// @dev Uses mainnet fork with real deployed Spark Prime ALM contracts
contract PrimeInitializationIntegrationTest is Test {

    // ========================================================================
    // Constants - Sky Protocol Addresses (from chainlog)
    // ========================================================================

    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
    address constant PSM = 0xf6e72Db5454dd049d0788e411b06CfAF16853042; // MCD_LITE_PSM_USDC_A
    address constant PAUSE_PROXY = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB; // MCD_PAUSE_PROXY

    // Spark Allocation System
    address constant ALLOCATOR_VAULT = 0x691a6c29e9e96dd897718305427Ad5D534db16BA;
    address constant ALLOCATOR_BUFFER = 0xc395D150e71378B47A1b8E9de0c1a83b75a08324;

    // ========================================================================
    // Constants - Spark Liquidity Layer Addresses
    // ========================================================================

    address constant ALM_CONTROLLER = 0xE52d643B27601D4d2BAB2052f30cf936ed413cec;
    address constant ALM_PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant ALM_RATE_LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant CCTP_TOKEN_MESSENGER = 0xBd3fa81B58Ba92a82136038B25aDec7066af3155;

    // Spark Governance
    address constant SPARK_PROXY = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;

    // ========================================================================
    // Constants - CCTP Domain IDs
    // ========================================================================

    uint32 constant DOMAIN_ID_CIRCLE_ETHEREUM = 0;
    uint32 constant DOMAIN_ID_CIRCLE_BASE = 6;
    uint32 constant DOMAIN_ID_CIRCLE_ARBITRUM = 3;

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
    uint256 constant HOP_DEFAULT = 18 hours;
    uint256 constant MAX_CHANGE_DEFAULT = 1.2e18; // 20% max increase

    // ========================================================================
    // Constants - BeamState Roles (see ROLES.md)
    // ========================================================================

    uint8 constant ROLE_CORE_COUNCIL_TIMELOCKED = 0;
    uint8 constant ROLE_CORE_COUNCIL_DIRECT = 1;

    // ========================================================================
    // State Variables - External Contracts
    // ========================================================================

    IERC20 usds;
    IERC20 usdc;

    IMainnetController mainnetController;
    IRateLimits rateLimits;
    IALMProxy almProxy;
    IVault vault;
    IPSM psm;

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
    // Events
    // ========================================================================

    event CCTPTransferInitiated(
        uint64 indexed nonce,
        uint32 indexed destinationDomain,
        bytes32 indexed mintRecipient,
        uint256 usdcAmount
    );

    // ========================================================================
    // Setup
    // ========================================================================

    function setUp() public {
        // Fork mainnet - uses ETH_RPC_URL env var, or falls back to public RPC
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth.llamarpc.com"));
        // Fork at latest block for compatibility with non-archive nodes
        vm.createSelectFork(rpcUrl);

        // Initialize external contracts
        usds = IERC20(USDS);
        usdc = IERC20(USDC);
        mainnetController = IMainnetController(ALM_CONTROLLER);
        rateLimits = IRateLimits(ALM_RATE_LIMITS);
        almProxy = IALMProxy(ALM_PROXY);
        vault = IVault(ALLOCATOR_VAULT);
        psm = IPSM(PSM);

        // Initialize test actors
        coreCouncil = makeAddr("coreCouncil");
        govOps = makeAddr("govOps");
        relayer = makeAddr("relayer");
        freezer = makeAddr("freezer");
        foreignPrime = makeAddr("foreignPrime");

        // Label addresses for better trace output
        vm.label(USDS, "USDS");
        vm.label(USDC, "USDC");
        vm.label(ALM_CONTROLLER, "MainnetController");
        vm.label(ALM_PROXY, "ALMProxy");
        vm.label(ALM_RATE_LIMITS, "RateLimits");
        vm.label(ALLOCATOR_VAULT, "Vault");
        vm.label(ALLOCATOR_BUFFER, "Buffer");
        vm.label(PSM, "PSM");
        vm.label(SPARK_PROXY, "SparkProxy");
        vm.label(PAUSE_PROXY, "PauseProxy");
    }

    // ========================================================================
    // Helper Functions
    // ========================================================================

    function _makeUint32Key(bytes32 baseKey, uint32 value) internal pure returns (bytes32) {
        return keccak256(abi.encode(baseKey, value));
    }

    function _deployPAUGovernance() internal {
        // Deploy BeamState
        beamState = new BeamState();

        // Deploy Configurator
        configurator = new Configurator(address(beamState));

        // Deploy Timelock with PAUSE_PROXY as admin
        // Note: We'll add wrapper as proposer after it's deployed
        address[] memory proposers = new address[](1);
        proposers[0] = coreCouncil;  // coreCouncil can schedule directly on timelock
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

        // Grant wrapper PROPOSER_ROLE on timelock so it can schedule operations
        // Cache PROPOSER_ROLE before pranking to avoid view call consuming the prank
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(PAUSE_PROXY);
        timelock.grantRole(proposerRole, address(wrapper));

        // Configure BeamState: add PAUSE_PROXY and timelock as wards
        beamState.rely(PAUSE_PROXY);
        beamState.rely(address(timelock));

        // Configure wrapper: add PAUSE_PROXY as ward and coreCouncil as bud
        wrapper.rely(PAUSE_PROXY);
        vm.startPrank(PAUSE_PROXY);
        wrapper.kiss(coreCouncil);  // coreCouncil can use wrapper functions
        vm.stopPrank();

        // IMPORTANT: Deny the test contract from BeamState and wrapper
        // All operations should go through proper governance actors
        beamState.deny(address(this));
        wrapper.deny(address(this));

        // Label deployed contracts
        vm.label(address(beamState), "BeamState");
        vm.label(address(configurator), "Configurator");
        vm.label(address(timelock), "Timelock");
        vm.label(address(wrapper), "TimelockWrapper");
    }

    /// @notice Set up BeamState roles per ROLES.md
    /// @dev Called via PAUSE_PROXY which is a ward
    function _setupBeamStateRoles() internal {
        vm.startPrank(PAUSE_PROXY);

        // =====================================================================
        // Role 0: Core Council Timelocked functions
        // These go through the timelock (executed by timelock address)
        // =====================================================================
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.start.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.setHop.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.setMaxChange.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.addRateLimits.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.addController.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.addCBeam.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, BeamState.addInitRateLimits.selector, true);
        beamState.setRoleAction(ROLE_CORE_COUNCIL_TIMELOCKED, bytes4(keccak256("addInitControllerActions(bytes,address)")), true);

        // =====================================================================
        // Role 1: Core Council Direct functions
        // These can be called directly by coreCouncil (no timelock)
        // =====================================================================
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

        // =====================================================================
        // Grant roles to actors
        // =====================================================================
        // coreCouncil gets the direct role (can call direct functions immediately)
        beamState.setUserRole(coreCouncil, ROLE_CORE_COUNCIL_DIRECT, true);

        // timelock gets the timelocked role (executes timelocked functions after delay)
        beamState.setUserRole(address(timelock), ROLE_CORE_COUNCIL_TIMELOCKED, true);

        vm.stopPrank();
    }

    /// @notice Execute a scheduled operation after warping past the delay
    function _warpAndExecute(bytes32 operationId) internal {
        // Get the operation timestamp
        uint256 readyTime = timelock.getTimestamp(operationId);
        require(readyTime > 0, "Operation not scheduled");

        // Warp past the ready time
        vm.warp(readyTime + 1);

        // The operation was scheduled as a batch, we need to reconstruct and execute
        // Since we don't have the original params stored, we'll use a different approach
    }

    /// @notice Schedule via wrapper and execute after timelock delay
    /// @dev Used for wrapper functions that don't expose the operation ID
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

        // Warp past timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Execute (permissionless after delay)
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    /// @notice Execute a batch operation that was scheduled via wrapper
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

        // Warp past timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Execute
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    // ========================================================================
    // Test: Complete Prime Initialization and Operation Flow
    // ========================================================================

    /// @notice Tests all phases of Prime initialization from deployment to operations
    function test_completePrimeInitializationAndOperationFlow() public {
        // ====================================================================
        // PHASE 1: Deploy PAU Governance Layer
        // ====================================================================

        _deployPAUGovernance();

        // Verify test contract is NOT a ward (we deny it in _deployPAUGovernance)
        assertEq(beamState.wards(address(this)), 0, "Test contract should not be ward");
        assertEq(beamState.wards(PAUSE_PROXY), 1, "PAUSE_PROXY should be ward");
        assertEq(wrapper.buds(coreCouncil), 1, "coreCouncil should be a bud on wrapper");

        // ====================================================================
        // PHASE 2: Set up BeamState roles (via PAUSE_PROXY)
        // ====================================================================

        _setupBeamStateRoles();

        // Verify roles are set up
        assertTrue(beamState.hasUserRole(coreCouncil, ROLE_CORE_COUNCIL_DIRECT), "coreCouncil should have direct role");
        assertTrue(beamState.hasUserRole(address(timelock), ROLE_CORE_COUNCIL_TIMELOCKED), "timelock should have timelocked role");

        // ====================================================================
        // PHASE 3: Configure BeamState defaults (via wrapper)
        // ====================================================================

        // Use wrapper.setHop() - schedules on timelock
        vm.prank(coreCouncil);
        wrapper.setHop(address(0), HOP_DEFAULT, bytes32(0), keccak256("setHop"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.setHop, (address(0), HOP_DEFAULT)),
            keccak256("setHop")
        );

        // Use wrapper.setMaxChange() - schedules on timelock
        vm.prank(coreCouncil);
        wrapper.setMaxChange(address(0), MAX_CHANGE_DEFAULT, bytes32(0), keccak256("setMaxChange"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.setMaxChange, (address(0), MAX_CHANGE_DEFAULT)),
            keccak256("setMaxChange")
        );

        assertEq(beamState.getHop(address(0)), HOP_DEFAULT, "Default hop should be set");
        assertEq(beamState.getMaxChange(address(0)), MAX_CHANGE_DEFAULT, "Default maxChange should be set");

        // ====================================================================
        // PHASE 4: Add Rate Limit Inits (via wrapper.batchAddInitRateLimits)
        // ====================================================================

        // Initialize rate limit parameters (stored in state to avoid stack issues)
        usdsMintMax = 10_000_000e18;  // 10M USDS
        usdsMintSlope = uint256(5_000_000e18) / 1 days;  // 5M per day refill
        usdsToUsdcMax = 10_000_000e6;  // 10M USDC (6 decimals)
        usdsToUsdcSlope = uint256(5_000_000e6) / 1 days;
        cctpMax = 5_000_000e6;  // 5M USDC
        cctpSlope = uint256(2_500_000e6) / 1 days;
        domainKeyBase = _makeUint32Key(LIMIT_USDC_TO_DOMAIN, DOMAIN_ID_CIRCLE_BASE);

        // Create batch config for all rate limits
        RateLimitConfig[] memory configs = new RateLimitConfig[](4);
        configs[0] = RateLimitConfig(LIMIT_USDS_MINT, address(0), usdsMintMax, usdsMintSlope);
        configs[1] = RateLimitConfig(LIMIT_USDS_TO_USDC, address(0), usdsToUsdcMax, usdsToUsdcSlope);
        configs[2] = RateLimitConfig(LIMIT_USDC_TO_CCTP, address(0), cctpMax, cctpSlope);
        configs[3] = RateLimitConfig(domainKeyBase, address(0), cctpMax, cctpSlope);

        vm.prank(coreCouncil);
        wrapper.batchAddInitRateLimits(configs, bytes32(0), keccak256("batchAddInitRateLimits"), TIMELOCK_DELAY);

        // Build the batch payloads for execution
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

        // ====================================================================
        // PHASE 5: Add Controller Action Inits (via wrapper.setMintRecipient)
        // ====================================================================

        // Use wrapper.setMintRecipient() which adds the controller action
        vm.prank(coreCouncil);
        wrapper.setMintRecipient(
            DOMAIN_ID_CIRCLE_BASE,
            bytes32(uint256(uint160(foreignPrime))),
            address(0),  // pau = address(0) means applies to all controllers
            bytes32(0),
            keccak256("setMintRecipient"),
            TIMELOCK_DELAY
        );

        // Build and execute the setMintRecipient scheduled batch
        bytes memory setMintRecipientCall = abi.encodeCall(
            IMainnetController.setMintRecipient,
            (DOMAIN_ID_CIRCLE_BASE, bytes32(uint256(uint160(foreignPrime))))
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

        // Add grantRole(RELAYER, relayer) action via wrapper.grantRole
        bytes32 RELAYER_ROLE = mainnetController.RELAYER();
        bytes memory grantRelayerCall = abi.encodeCall(
            IMainnetController.grantRole,
            (RELAYER_ROLE, relayer)
        );

        vm.prank(coreCouncil);
        wrapper.grantRole(ALM_CONTROLLER, RELAYER_ROLE, relayer, bytes32(0), keccak256("grantRelayer"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeWithSelector(
                bytes4(keccak256("addInitControllerActions(bytes,address)")),
                grantRelayerCall,
                ALM_CONTROLLER
            ),
            keccak256("grantRelayer")
        );

        // Verify controller actions are enabled
        assertTrue(
            beamState.isControllerActionEnabled(keccak256(setMintRecipientCall), ALM_CONTROLLER),
            "setMintRecipient action should be enabled"
        );
        assertTrue(
            beamState.isControllerActionEnabled(keccak256(grantRelayerCall), ALM_CONTROLLER),
            "grantRole(RELAYER) action should be enabled"
        );

        // ====================================================================
        // PHASE 6: Register contracts and cBeams (timelocked + direct)
        // ====================================================================
        // - addCBeam, addRateLimits, addController are TIMELOCKED
        // - setCBeamForRateLimits, setCBeamForController are DIRECT

        // Use wrapper.addCBeam()
        vm.prank(coreCouncil);
        wrapper.addCBeam(govOps, bytes32(0), keccak256("addCBeam_govOps"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.addCBeam, (govOps)),
            keccak256("addCBeam_govOps")
        );

        // Timelocked: Whitelist ALM_RATE_LIMITS via wrapper.addRateLimits
        vm.prank(coreCouncil);
        wrapper.addRateLimits(ALM_RATE_LIMITS, bytes32(0), keccak256("addRateLimits"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.addRateLimits, (ALM_RATE_LIMITS)),
            keccak256("addRateLimits")
        );

        // Timelocked: Whitelist ALM_CONTROLLER via wrapper.addController
        vm.prank(coreCouncil);
        wrapper.addController(ALM_CONTROLLER, bytes32(0), keccak256("addController"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.addController, (ALM_CONTROLLER)),
            keccak256("addController")
        );

        // Direct: Associate govOps as cBeam for RateLimits (coreCouncil direct role)
        vm.prank(coreCouncil);
        beamState.setCBeamForRateLimits(ALM_RATE_LIMITS, govOps);

        // Direct: Associate govOps as cBeam for Controller (coreCouncil direct role)
        vm.prank(coreCouncil);
        beamState.setCBeamForController(ALM_CONTROLLER, govOps);

        // Verify associations
        assertEq(beamState.rateLimitsCBeams(ALM_RATE_LIMITS, govOps), 1, "govOps should be cBeam for RateLimits");
        assertEq(beamState.controllersCBeams(ALM_CONTROLLER, govOps), 1, "govOps should be cBeam for Controller");

        // ====================================================================
        // PHASE 7: Grant Configurator admin roles on target contracts
        // ====================================================================
        // This is done via SPARK_PROXY (the admin of the existing ALM contracts)

        vm.startPrank(SPARK_PROXY);
        rateLimits.grantRole(rateLimits.DEFAULT_ADMIN_ROLE(), address(configurator));
        mainnetController.grantRole(mainnetController.DEFAULT_ADMIN_ROLE(), address(configurator));
        vm.stopPrank();

        // ====================================================================
        // PHASE 8: Configure PAU via Configurator (GovOps as cBeam)
        // ====================================================================

        vm.startPrank(govOps);

        // Set rate limits
        configurator.setRateLimit(ALM_RATE_LIMITS, LIMIT_USDS_MINT, usdsMintMax, usdsMintSlope);
        configurator.setRateLimit(ALM_RATE_LIMITS, LIMIT_USDS_TO_USDC, usdsToUsdcMax, usdsToUsdcSlope);
        configurator.setRateLimit(ALM_RATE_LIMITS, LIMIT_USDC_TO_CCTP, cctpMax, cctpSlope);
        configurator.setRateLimit(ALM_RATE_LIMITS, domainKeyBase, cctpMax, cctpSlope);

        // Set mint recipient via controller action
        configurator.callControllerAction(ALM_CONTROLLER, setMintRecipientCall);

        // Grant relayer role via controller action (instead of pranking SPARK_PROXY)
        configurator.callControllerAction(ALM_CONTROLLER, grantRelayerCall);

        vm.stopPrank();

        // Verify configuration
        assertTrue(mainnetController.hasRole(RELAYER_ROLE, relayer), "Relayer should have RELAYER role");
        assertEq(
            mainnetController.mintRecipients(DOMAIN_ID_CIRCLE_BASE),
            bytes32(uint256(uint160(foreignPrime))),
            "Mint recipient should be set for Base"
        );

        // ====================================================================
        // PHASE 9-11: Execute Operations
        // ====================================================================

        _executePhase9_MintUSDS(relayer);
        _executePhase10_SwapUSDSToUSDC(relayer);
        _executePhase11_TransferCCTP(relayer, domainKeyBase);

        // ====================================================================
        // Summary Logs
        // ====================================================================

        emit log("=== Prime Initialization Complete ===");
        emit log_named_address("ALM Controller", ALM_CONTROLLER);
        emit log_named_address("ALM Proxy", ALM_PROXY);
        emit log_named_address("Rate Limits", ALM_RATE_LIMITS);
        emit log_named_address("Relayer", relayer);
        emit log_named_uint("Final ALM Proxy USDS balance", usds.balanceOf(ALM_PROXY));
        emit log_named_uint("Final ALM Proxy USDC balance", usdc.balanceOf(ALM_PROXY));
    }

    function _executePhase9_MintUSDS(address _relayer) internal {
        uint256 mintAmount = 1_000_000e18; // 1M USDS

        uint256 proxyUsdsBalanceBefore = usds.balanceOf(ALM_PROXY);
        uint256 rateLimitBefore = rateLimits.getCurrentRateLimit(LIMIT_USDS_MINT);

        vm.prank(_relayer);
        mainnetController.mintUSDS(mintAmount);

        uint256 proxyUsdsBalanceAfter = usds.balanceOf(ALM_PROXY);
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
        emit log_named_uint("ALM Proxy USDS balance", proxyUsdsBalanceAfter);
    }

    function _executePhase10_SwapUSDSToUSDC(address _relayer) internal {
        uint256 swapAmount = 500_000e6; // 500K USDC (note: 6 decimals)

        uint256 proxyUsdcBalanceBefore = usdc.balanceOf(ALM_PROXY);
        uint256 swapRateLimitBefore = rateLimits.getCurrentRateLimit(LIMIT_USDS_TO_USDC);

        vm.prank(_relayer);
        mainnetController.swapUSDSToUSDC(swapAmount);

        uint256 proxyUsdcBalanceAfter = usdc.balanceOf(ALM_PROXY);
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
        emit log_named_uint("ALM Proxy USDC balance", proxyUsdcBalanceAfter);
    }

    function _executePhase11_TransferCCTP(address _relayer, bytes32 domainKey) internal {
        uint256 transferAmount = 100_000e6; // 100K USDC

        uint256 proxyUsdcBefore = usdc.balanceOf(ALM_PROXY);
        uint256 cctpLimitBefore = rateLimits.getCurrentRateLimit(LIMIT_USDC_TO_CCTP);
        uint256 domainLimitBefore = rateLimits.getCurrentRateLimit(domainKey);
        uint256 supplyBefore = usdc.totalSupply();

        vm.prank(_relayer);
        mainnetController.transferUSDCToCCTP(transferAmount, DOMAIN_ID_CIRCLE_BASE);

        uint256 proxyUsdcAfter = usdc.balanceOf(ALM_PROXY);
        uint256 cctpLimitAfter = rateLimits.getCurrentRateLimit(LIMIT_USDC_TO_CCTP);
        uint256 domainLimitAfter = rateLimits.getCurrentRateLimit(domainKey);
        uint256 supplyAfter = usdc.totalSupply();

        assertEq(proxyUsdcBefore - proxyUsdcAfter, transferAmount, "ALM Proxy USDC should have decreased");
        assertEq(cctpLimitBefore - cctpLimitAfter, transferAmount, "CCTP rate limit should have decreased");
        assertEq(domainLimitBefore - domainLimitAfter, transferAmount, "Domain rate limit should have decreased");
        assertEq(supplyBefore - supplyAfter, transferAmount, "USDC should have been burned for CCTP transfer");

        emit log_named_uint("USDC transferred via CCTP", transferAmount);
        emit log_named_uint("USDC burned (supply decrease)", supplyBefore - supplyAfter);
    }

    /// @notice Tests Configurator setRateLimit respects SORL constraints
    function test_configurator_sorlConstraints() public {
        _deployPAUGovernance();
        _setupBeamStateRoles();

        // Setup beamState defaults (via wrapper)
        vm.prank(coreCouncil);
        wrapper.setHop(address(0), 18 hours, bytes32(0), keccak256("setHop"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.setHop, (address(0), 18 hours)),
            keccak256("setHop")
        );

        vm.prank(coreCouncil);
        wrapper.setMaxChange(address(0), 1.2e18, bytes32(0), keccak256("setMaxChange"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.setMaxChange, (address(0), 1.2e18)),
            keccak256("setMaxChange")
        );

        // Add govOps as cBeam (via wrapper)
        vm.prank(coreCouncil);
        wrapper.addCBeam(govOps, bytes32(0), keccak256("addCBeam"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.addCBeam, (govOps)),
            keccak256("addCBeam")
        );

        // Whitelist ALM_RATE_LIMITS via wrapper.addRateLimits
        vm.prank(coreCouncil);
        wrapper.addRateLimits(ALM_RATE_LIMITS, bytes32(0), keccak256("addRateLimits"), TIMELOCK_DELAY);
        _executeScheduledBatch(
            address(beamState),
            abi.encodeCall(BeamState.addRateLimits, (ALM_RATE_LIMITS)),
            keccak256("addRateLimits")
        );

        // Associate govOps with ALM_RATE_LIMITS (direct)
        vm.prank(coreCouncil);
        beamState.setCBeamForRateLimits(ALM_RATE_LIMITS, govOps);

        // Add high init rate limits (via wrapper)
        uint256 highInitMax = 1_000_000_000e18; // 1 billion
        uint256 highInitSlope = uint256(500_000_000e18) / 1 days;

        RateLimitConfig[] memory configs = new RateLimitConfig[](1);
        configs[0] = RateLimitConfig(LIMIT_USDS_MINT, address(0), highInitMax, highInitSlope);

        vm.prank(coreCouncil);
        wrapper.batchAddInitRateLimits(configs, bytes32(0), keccak256("addInitRateLimits"), TIMELOCK_DELAY);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        targets[0] = address(beamState);
        values[0] = 0;
        payloads[0] = abi.encodeCall(BeamState.addInitRateLimits, (LIMIT_USDS_MINT, address(0), highInitMax, highInitSlope));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.executeBatch(targets, values, payloads, bytes32(0), keccak256("addInitRateLimits"));

        // Grant the Configurator contract admin role on RateLimits
        bytes32 adminRole = rateLimits.DEFAULT_ADMIN_ROLE();
        vm.prank(SPARK_PROXY);
        rateLimits.grantRole(adminRole, address(configurator));

        // Get current deployed values
        IRateLimits.RateLimitData memory current = rateLimits.getRateLimitData(LIMIT_USDS_MINT);

        // First set: increase above current values to trigger zzz update
        uint256 newMax = current.maxAmount + 1e18;
        uint256 newSlope = current.slope + 1;
        vm.prank(govOps);
        configurator.setRateLimit(ALM_RATE_LIMITS, LIMIT_USDS_MINT, newMax, newSlope);

        // Try to increase again immediately - should fail because hop hasn't passed
        vm.prank(govOps);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(ALM_RATE_LIMITS, LIMIT_USDS_MINT, newMax + 1e18, newSlope + 1);

        // Warp past hop period
        vm.warp(block.timestamp + 18 hours + 1);

        // Try 50% increase - should fail maxChange check
        vm.prank(govOps);
        vm.expectRevert("Configurator/maxChange-maxAmount");
        configurator.setRateLimit(ALM_RATE_LIMITS, LIMIT_USDS_MINT, newMax * 150 / 100, newSlope);

        // 20% increase should work
        vm.prank(govOps);
        configurator.setRateLimit(ALM_RATE_LIMITS, LIMIT_USDS_MINT, newMax * 120 / 100, newSlope * 120 / 100);
    }

    // ========================================================================
    // Internal Helper
    // ========================================================================

    function _getInitRateLimits(bytes32 key, address rateLimits_) internal view returns (uint256, uint256) {
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, rateLimits_);
        return (limits.maxAmount, limits.slope);
    }
}
