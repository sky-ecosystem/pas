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
import { TimelockWrapperMainnet, RateLimitConfig } from "src/timelock/TimelockWrapperMainnet.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { BeamState } from "src/BeamState.sol";
import { Configurator } from "src/Configurator.sol";
import { PASDeploy } from "deploy/PASDeploy.sol";
import { PASInit } from "deploy/PASInit.sol";
import { PASInstance } from "deploy/PASInstance.sol";

interface ControllerLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function RELAYER() external view returns (bytes32);
    function mintRecipients(uint32) external view returns (bytes32);
    function rateLimits() external view returns (address);
    // Shared getters
    function layerZeroRecipients(uint32) external view returns (bytes32);
    function maxSlippages(address) external view returns (uint256);
    function maxExchangeRates(address) external view returns (uint256);
    // Spark-specific getters
    // otcs returns: (buffer, rechargeRate18, sent18, sentTimestamp, claimed18)
    function otcs(address) external view returns (address, uint256, uint256, uint256, uint256);
    function otcWhitelistedAssets(address, address) external view returns (bool);
    // Grove-specific getters
    function centrifugeRecipients(uint16) external view returns (bytes32);
    // uniswapV3PoolParams returns: (swapMaxTickDelta, addLiquidityLowerTick, addLiquidityUpperTick, twapSecondsAgo)
    function uniswapV3PoolParams(address) external view returns (uint24, int24, int24, uint32);

    function grantRole(bytes32 role, address account) external;
}

interface RateLimitsLike {
    function grantRole(bytes32 role, address account) external;
    function getRateLimitData(bytes32 key) external view returns (uint256, uint256, uint256, uint256);
}

contract TimelockWrapperMainnetTest is DssTest {
    // --- Events ---
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event ProposalSubmitted(bytes32 indexed operationId, string functionName);

    // --- Mainnet Addresses ---
    // https://github.com/sparkdotfi/spark-address-registry/blob/0a06d13c3e9d36428a6f916ac25528d82154517b/src/Ethereum.sol
    address constant SPARK_CONTROLLER = 0xE52d643B27601D4d2BAB2052f30cf936ed413cec;
    address constant SPARK_PROXY      = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;

    // https://github.com/grove-labs/grove-address-registry/blob/dd625925ab44e89eadce0cb4258e32aae2dfa73e/src/Ethereum.sol
    address constant GROVE_CONTROLLER = 0xfd9dEA9a8D5B955649579Af482DB7198A392A9F5;
    address constant GROVE_PROXY      = 0x1369f7b2b38c76B6478c0f0E66D94923421891Ba;

    address constant CHAINLOG         = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    uint256 constant MIN_DELAY  = 1 days;

    bytes32 constant OZ_DEFAULT_ADMIN_ROLE = bytes32(0);

    DssInstance dss;

    // --- Fetched from controllers ---
    address SPARK_RATE_LIMITS;
    address GROVE_RATE_LIMITS;

    // --- PAS Instance ---
    BeamState              beamState;
    Configurator           configurator;
    Timelock               timelock;
    TimelockWrapperMainnet wrapper;

    address pauseProxy;
    address coreCouncil;
    address cBeam;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        // Load DssInstance from chainlog
        dss = MCD.loadFromChainlog(CHAINLOG);

        // Fetch rate limits from controllers
        SPARK_RATE_LIMITS = ControllerLike(SPARK_CONTROLLER).rateLimits();
        GROVE_RATE_LIMITS = ControllerLike(GROVE_CONTROLLER).rateLimits();

        coreCouncil = makeAddr("coreCouncil");
        cBeam       = makeAddr("cBeam");

        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");

        PASInstance memory pas = PASDeploy.deploy(address(this), pauseProxy, MIN_DELAY);
        beamState    = BeamState(pas.beamState);
        configurator = Configurator(pas.configurator);
        timelock     = Timelock(payable(pas.timelock));
        wrapper      = TimelockWrapperMainnet(PASDeploy.deployTimelockWrapperMainnet(address(this), pauseProxy, pas.timelock, pas.beamState));

        vm.startPrank(pauseProxy);
        PASInit.init(pas, MIN_DELAY, coreCouncil, new address[](0), new address[](0));
        PASInit.initTimelockWrapper(pas, address(wrapper), coreCouncil);
        vm.stopPrank();

        // Grant configurator admin role on mainnet controllers and rate limiters
        vm.startPrank(SPARK_PROXY);
        ControllerLike(SPARK_CONTROLLER).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));
        RateLimitsLike(SPARK_RATE_LIMITS).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));
        vm.stopPrank();

        vm.startPrank(GROVE_PROXY);
        ControllerLike(GROVE_CONTROLLER).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));
        RateLimitsLike(GROVE_RATE_LIMITS).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));
        vm.stopPrank();

        // Setup controllers, rate limiters, and cBeam in BeamState
        vm.startPrank(coreCouncil);
        bytes32 id;
        id = wrapper.addController(SPARK_CONTROLLER, bytes32(0), keccak256("spark-ctrl"), MIN_DELAY);
        _execute(id);
        id = wrapper.addController(GROVE_CONTROLLER, bytes32(0), keccak256("grove-ctrl"), MIN_DELAY);
        _execute(id);
        id = wrapper.addRateLimits(SPARK_RATE_LIMITS, bytes32(0), keccak256("spark-rl"), MIN_DELAY);
        _execute(id);
        id = wrapper.addRateLimits(GROVE_RATE_LIMITS, bytes32(0), keccak256("grove-rl"), MIN_DELAY);
        _execute(id);
        id = wrapper.addCBeam(cBeam, bytes32(0), keccak256("cbeam"), MIN_DELAY);
        _execute(id);

        // Verify wrapper correctly configured BeamState
        assertEq(beamState.controllers(SPARK_CONTROLLER), 1, "Spark controller not added");
        assertEq(beamState.controllers(GROVE_CONTROLLER), 1, "Grove controller not added");
        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 1, "Spark rate limits not added");
        assertEq(beamState.rateLimits(GROVE_RATE_LIMITS), 1, "Grove rate limits not added");
        assertEq(beamState.cBeams(cBeam), 1, "cBeam not added");

        // Link cBeam to controllers/rate limiters
        beamState.setCBeamForController(SPARK_CONTROLLER, cBeam);
        beamState.setCBeamForController(GROVE_CONTROLLER, cBeam);
        beamState.setCBeamForRateLimits(SPARK_RATE_LIMITS, cBeam);
        beamState.setCBeamForRateLimits(GROVE_RATE_LIMITS, cBeam);
        vm.stopPrank();

        // Set hop for rate limiters (required for setRateLimit to work on increases)
        vm.startPrank(coreCouncil);
        bytes32 hopId;
        hopId = wrapper.setHop(SPARK_RATE_LIMITS, 1 hours, bytes32(0), keccak256("spark-hop"), MIN_DELAY);
        _execute(hopId);
        hopId = wrapper.setHop(GROVE_RATE_LIMITS, 1 hours, bytes32(0), keccak256("grove-hop"), MIN_DELAY);
        _execute(hopId);
        vm.stopPrank();
    }

    // ============================================================================
    // Helpers
    // ============================================================================

    function _execute(bytes32 id) internal {
        vm.warp(block.timestamp + MIN_DELAY);
        Timelock.Operation memory op = timelock.getOperation(id);
        timelock.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
    }

    function _getControllerAction(bytes32 id) internal view returns (bytes memory data, address controller) {
        Timelock.Operation memory op = timelock.getOperation(id);
        // Decode payload: selector (4 bytes) || abi.encode(data, controller)
        bytes memory payload = op.payloads[0];
        assembly {
            payload := add(payload, 4)
        }
        (data, controller) = abi.decode(payload, (bytes, address));
    }

    function _expectedOperationId(bytes memory payload, bytes32 predecessor, bytes32 salt) internal view returns (bytes32) {
        address[] memory targets = new address[](1);
        targets[0] = address(beamState);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        return timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
    }

    // ============================================================================
    // Authorization Tests
    // ============================================================================

    function testConstructor() public {
        vm.expectEmit();
        emit Rely(address(this));
        TimelockWrapperMainnet newWrapper = new TimelockWrapperMainnet(address(timelock), address(beamState));

        assertEq(address(newWrapper.timelock()), address(timelock), "Timelock set correctly");
        assertEq(address(newWrapper.beamState()), address(beamState), "BeamState set correctly");
        assertEq(newWrapper.wards(address(this)), 1, "Deployer is ward");
    }

    function testAuth() public {
        checkAuth(address(wrapper), "TimelockWrapperMainnet");
    }

    function testKissDiss() public {
        address usr = makeAddr("usr");

        vm.startPrank(pauseProxy);
        assertEq(wrapper.buds(usr), 0);
        vm.expectEmit();
        emit Kiss(usr);
        wrapper.kiss(usr);
        assertEq(wrapper.buds(usr), 1);
        vm.expectEmit();
        emit Diss(usr);
        wrapper.diss(usr);
        assertEq(wrapper.buds(usr), 0);
        vm.stopPrank();
    }

    function testAuthModifiers() public {
        bytes4[] memory authedMethods = new bytes4[](2);
        authedMethods[0] = wrapper.kiss.selector;
        authedMethods[1] = wrapper.diss.selector;

        vm.startPrank(address(0xBEEF));
        checkModifier(address(wrapper), "TimelockWrapperMainnet/not-authorized", authedMethods);
        vm.stopPrank();
    }

    function testTollModifiers() public {
        bytes4[] memory tolledMethods = new bytes4[](22);
        tolledMethods[0]  = wrapper.start.selector;
        tolledMethods[1]  = wrapper.setHop.selector;
        tolledMethods[2]  = wrapper.setMaxChange.selector;
        tolledMethods[3]  = wrapper.addRateLimits.selector;
        tolledMethods[4]  = wrapper.addController.selector;
        tolledMethods[5]  = wrapper.addCBeam.selector;
        tolledMethods[6]  = wrapper.addInitRateLimits.selector;
        tolledMethods[7]  = wrapper.batchAddInitRateLimits.selector;
        tolledMethods[8]  = wrapper.grantRole.selector;
        tolledMethods[9]  = wrapper.revokeRole.selector;
        tolledMethods[10] = wrapper.setMintRecipient.selector;
        tolledMethods[11] = wrapper.setLayerZeroRecipient.selector;
        tolledMethods[12] = wrapper.setMaxSlippage.selector;
        tolledMethods[13] = wrapper.setOTCBuffer.selector;
        tolledMethods[14] = wrapper.setOTCRechargeRate.selector;
        tolledMethods[15] = wrapper.setOTCWhitelistedAsset.selector;
        tolledMethods[16] = wrapper.setMaxExchangeRate.selector;
        tolledMethods[17] = wrapper.setUniswapV3PoolMaxTickDelta.selector;
        tolledMethods[18] = wrapper.setUniswapV3AddLiquidityLowerTickBound.selector;
        tolledMethods[19] = wrapper.setUniswapV3AddLiquidityUpperTickBound.selector;
        tolledMethods[20] = wrapper.setUniswapV3TwapSecondsAgo.selector;
        tolledMethods[21] = wrapper.setCentrifugeRecipient.selector;

        vm.startPrank(address(0xBEEF));
        checkModifier(address(wrapper), "TimelockWrapperMainnet/not-whitelisted", tolledMethods);
        vm.stopPrank();
    }

    // ============================================================================
    // BeamState Configuration Tests
    // ============================================================================

    function testStart() public {
        vm.prank(coreCouncil);
        beamState.stop();
        assertTrue(beamState.stopped());

        bytes32 salt = keccak256("start");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.start.selector), bytes32(0), salt);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "start");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.start(bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        _execute(id);

        assertFalse(beamState.stopped());
    }

    function testSetHop() public {
        bytes32 salt = keccak256("hop");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.setHop.selector, SPARK_RATE_LIMITS, 3600), bytes32(0), salt);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setHop");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setHop(SPARK_RATE_LIMITS, 3600, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.getHop(SPARK_RATE_LIMITS), 3600);
    }

    function testSetMaxChange() public {
        bytes32 salt = keccak256("mc");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.setMaxChange.selector, GROVE_RATE_LIMITS, 2e18), bytes32(0), salt);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setMaxChange");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setMaxChange(GROVE_RATE_LIMITS, 2e18, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.maxChange(GROVE_RATE_LIMITS), 2e18);
    }

    function testAddRateLimits() public {
        address rateLimits = makeAddr("rateLimits");
        bytes32 salt = keccak256("rl");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.addRateLimits.selector, rateLimits), bytes32(0), salt);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "addRateLimits");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.addRateLimits(rateLimits, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.rateLimits(rateLimits), 1);
    }

    function testAddController() public {
        address controller = makeAddr("controller");
        bytes32 salt = keccak256("ctrl");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.addController.selector, controller), bytes32(0), salt);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "addController");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.addController(controller, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.controllers(controller), 1);
    }

    function testAddCBeam() public {
        address beam = makeAddr("beam");
        bytes32 salt = keccak256("cbeam");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.addCBeam.selector, beam), bytes32(0), salt);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "addCBeam");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.addCBeam(beam, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.cBeams(beam), 1);
    }

    function _checkAddInitRateLimits(address rateLimits, bytes32 key, bytes32 salt) internal {
        RateLimitConfig memory config = RateLimitConfig({
            key: key,
            rateLimits: rateLimits,
            maxAmount: 10_000_000e18,
            slope: 1_000_000e18
        });

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitRateLimits.selector, config.key, config.rateLimits, config.maxAmount, config.slope),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "addInitRateLimits");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.addInitRateLimits(config, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        _execute(id);

        // Verify stored in BeamState
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(config.key, rateLimits);
        assertEq(limits.maxAmount, config.maxAmount);
        assertEq(limits.slope, config.slope);

        // Execute on real rate limiter via Configurator
        vm.prank(cBeam);
        configurator.setRateLimit(rateLimits, config.key, config.maxAmount, config.slope);

        // Verify set on real rate limiter
        (uint256 setMax, uint256 setSlope,,) = RateLimitsLike(rateLimits).getRateLimitData(config.key);
        assertEq(setMax, config.maxAmount);
        assertEq(setSlope, config.slope);
    }

    function testAddInitRateLimitsOnSpark() public {
        _checkAddInitRateLimits(SPARK_RATE_LIMITS, keccak256("spark-deposit"), keccak256("initS"));
    }

    function testAddInitRateLimitsOnGrove() public {
        _checkAddInitRateLimits(GROVE_RATE_LIMITS, keccak256("grove-deposit"), keccak256("initG"));
    }

    function _checkBatchAddInitRateLimits(address rateLimits, bytes32 key1, bytes32 key2, bytes32 salt) internal {
        RateLimitConfig[] memory configs = new RateLimitConfig[](2);
        configs[0] = RateLimitConfig(key1, rateLimits, 5_000_000e18, 500_000e18);
        configs[1] = RateLimitConfig(key2, rateLimits, 3_000_000e18, 300_000e18);

        // Pre-compute expected operationId for batch
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        for (uint256 i = 0; i < 2; i++) {
            targets[i] = address(beamState);
            payloads[i] = abi.encodeWithSelector(BeamState.addInitRateLimits.selector, configs[i].key, configs[i].rateLimits, configs[i].maxAmount, configs[i].slope);
        }
        bytes32 expectedId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "batchAddInitRateLimits");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.batchAddInitRateLimits(configs, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        assertEq(timelock.getOperationCount(), 1);

        vm.warp(block.timestamp + MIN_DELAY);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        // Verify stored in BeamState
        assertEq(beamState.getInitRateLimits(configs[0].key, rateLimits).maxAmount, configs[0].maxAmount);
        assertEq(beamState.getInitRateLimits(configs[1].key, rateLimits).maxAmount, configs[1].maxAmount);

        // Execute on real rate limiter via Configurator
        vm.startPrank(cBeam);
        configurator.setRateLimit(rateLimits, configs[0].key, configs[0].maxAmount, configs[0].slope);
        configurator.setRateLimit(rateLimits, configs[1].key, configs[1].maxAmount, configs[1].slope);
        vm.stopPrank();

        // Verify set on real rate limiter
        (uint256 max0, uint256 slope0,,) = RateLimitsLike(rateLimits).getRateLimitData(configs[0].key);
        assertEq(max0, configs[0].maxAmount);
        assertEq(slope0, configs[0].slope);

        (uint256 max1, uint256 slope1,,) = RateLimitsLike(rateLimits).getRateLimitData(configs[1].key);
        assertEq(max1, configs[1].maxAmount);
        assertEq(slope1, configs[1].slope);
    }

    function testBatchAddInitRateLimitsOnSpark() public {
        _checkBatchAddInitRateLimits(SPARK_RATE_LIMITS, keccak256("spark-batch-1"), keccak256("spark-batch-2"), keccak256("batchS"));
    }

    function testBatchAddInitRateLimitsOnGrove() public {
        _checkBatchAddInitRateLimits(GROVE_RATE_LIMITS, keccak256("grove-batch-1"), keccak256("grove-batch-2"), keccak256("batchG"));
    }

    // ============================================================================
    // Controller Action Tests
    // ============================================================================

    // --- grantRole (Spark & Grove) ---

    function _checkGrantRole(address controller, bytes32 salt) internal {
        bytes32 role = ControllerLike(controller).RELAYER();
        address account = makeAddr("relayer");

        assertFalse(ControllerLike(controller).hasRole(role, account));

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("grantRole(bytes32,address)", role, account), controller),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "grantRole");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.grantRole(controller, role, account, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertTrue(ControllerLike(controller).hasRole(role, account));
    }

    function testGrantRoleOnSparkController() public {
        _checkGrantRole(SPARK_CONTROLLER, keccak256("grantS"));
    }

    function testGrantRoleOnGroveController() public {
        _checkGrantRole(GROVE_CONTROLLER, keccak256("grantG"));
    }

    // --- revokeRole (Spark & Grove) ---

    function _checkRevokeRole(address controller, address admin, bytes32 salt) internal {
        bytes32 role = ControllerLike(controller).RELAYER();
        address account = makeAddr("toRevoke");

        vm.prank(admin);
        ControllerLike(controller).grantRole(role, account);

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("revokeRole(bytes32,address)", role, account), controller),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "revokeRole");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.revokeRole(controller, role, account, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertFalse(ControllerLike(controller).hasRole(role, account));
    }

    function testRevokeRoleOnSparkController() public {
        _checkRevokeRole(SPARK_CONTROLLER, SPARK_PROXY, keccak256("revokeS"));
    }

    function testRevokeRoleOnGroveController() public {
        _checkRevokeRole(GROVE_CONTROLLER, GROVE_PROXY, keccak256("revokeG"));
    }

    // --- setMintRecipient (Spark & Grove) ---

    function _checkSetMintRecipient(address controller, bytes32 salt) internal {
        uint32 domain = 6;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("recipient"))));

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setMintRecipient(uint32,bytes32)", domain, recipient), controller),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setMintRecipient");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setMintRecipient(domain, recipient, controller, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertEq(ControllerLike(controller).mintRecipients(domain), recipient);
    }

    function testSetMintRecipientOnSparkController() public {
        _checkSetMintRecipient(SPARK_CONTROLLER, keccak256("mintS"));
    }

    function testSetMintRecipientOnGroveController() public {
        _checkSetMintRecipient(GROVE_CONTROLLER, keccak256("mintG"));
    }

    // --- setLayerZeroRecipient (Spark & Grove) ---

    function _checkSetLayerZeroRecipient(address controller, bytes32 salt) internal {
        uint32 endpointId = 111;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("lzRecipient"))));

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setLayerZeroRecipient(uint32,bytes32)", endpointId, recipient), controller),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setLayerZeroRecipient");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setLayerZeroRecipient(endpointId, recipient, controller, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertEq(ControllerLike(controller).layerZeroRecipients(endpointId), recipient);
    }

    function testSetLayerZeroRecipientOnSparkController() public {
        _checkSetLayerZeroRecipient(SPARK_CONTROLLER, keccak256("lzS"));
    }

    function testSetLayerZeroRecipientOnGroveController() public {
        _checkSetLayerZeroRecipient(GROVE_CONTROLLER, keccak256("lzG"));
    }

    // --- setMaxSlippage (Spark & Grove) ---

    function _checkSetMaxSlippage(address controller, bytes32 salt) internal {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        uint256 slippage = 100;

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setMaxSlippage(address,uint256)", pool, slippage), controller),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setMaxSlippage");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setMaxSlippage(pool, slippage, controller, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertEq(ControllerLike(controller).maxSlippages(pool), slippage);
    }

    function testSetMaxSlippageOnSparkController() public {
        _checkSetMaxSlippage(SPARK_CONTROLLER, keccak256("slipS"));
    }

    function testSetMaxSlippageOnGroveController() public {
        _checkSetMaxSlippage(GROVE_CONTROLLER, keccak256("slipG"));
    }

    // --- setOTCBuffer (Spark Only) ---

    function testSetOTCBufferOnSparkController() public {
        address exchange = makeAddr("exchange");
        address buffer = makeAddr("buffer");
        bytes32 salt = keccak256("buf");

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setOTCBuffer(address,address)", exchange, buffer), SPARK_CONTROLLER),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setOTCBuffer");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setOTCBuffer(exchange, buffer, SPARK_CONTROLLER, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(SPARK_CONTROLLER, data);
        (address setBuffer,,,,) = ControllerLike(SPARK_CONTROLLER).otcs(exchange);
        assertEq(setBuffer, buffer);
    }

    // --- setOTCRechargeRate (Spark Only) ---

    function testSetOTCRechargeRateOnSparkController() public {
        address exchange = makeAddr("exchange");
        bytes32 salt = keccak256("rate");

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setOTCRechargeRate(address,uint256)", exchange, 1e18), SPARK_CONTROLLER),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setOTCRechargeRate");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setOTCRechargeRate(exchange, 1e18, SPARK_CONTROLLER, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(SPARK_CONTROLLER, data);
        (, uint256 rechargeRate,,,) = ControllerLike(SPARK_CONTROLLER).otcs(exchange);
        assertEq(rechargeRate, 1e18);
    }

    // --- setOTCWhitelistedAsset (Spark Only) ---

    function testSetOTCWhitelistedAssetOnSparkController() public {
        address exchange = makeAddr("exchange");
        address buffer = makeAddr("buffer");
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // First set the buffer (required before whitelisting assets)
        {
            bytes32 expectedId = _expectedOperationId(
                abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setOTCBuffer(address,address)", exchange, buffer), SPARK_CONTROLLER),
                bytes32(0),
                keccak256("wlbuf")
            );

            vm.expectEmit(true, true, true, true, address(wrapper));
            emit ProposalSubmitted(expectedId, "setOTCBuffer");
            vm.prank(coreCouncil);
            bytes32 id = wrapper.setOTCBuffer(exchange, buffer, SPARK_CONTROLLER, bytes32(0), keccak256("wlbuf"), MIN_DELAY);
            assertEq(id, expectedId);
            (bytes memory data,) = _getControllerAction(id);
            _execute(id);
            vm.prank(cBeam);
            configurator.callControllerAction(SPARK_CONTROLLER, data);
        }

        // Now whitelist the asset
        {
            bytes32 expectedId = _expectedOperationId(
                abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setOTCWhitelistedAsset(address,address,bool)", exchange, usdc, true), SPARK_CONTROLLER),
                bytes32(0),
                keccak256("wl")
            );

            vm.expectEmit(true, true, true, true, address(wrapper));
            emit ProposalSubmitted(expectedId, "setOTCWhitelistedAsset");
            vm.prank(coreCouncil);
            bytes32 id = wrapper.setOTCWhitelistedAsset(exchange, usdc, true, SPARK_CONTROLLER, bytes32(0), keccak256("wl"), MIN_DELAY);
            assertEq(id, expectedId);
            (bytes memory data,) = _getControllerAction(id);
            _execute(id);

            vm.prank(cBeam);
            configurator.callControllerAction(SPARK_CONTROLLER, data);
        }

        assertTrue(ControllerLike(SPARK_CONTROLLER).otcWhitelistedAssets(exchange, usdc));
    }

    // --- setMaxExchangeRate (Spark & Grove) ---

    function _checkSetMaxExchangeRate(address controller, bytes32 salt) internal {
        address sDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
        uint256 shares = 1e18;
        uint256 maxExpectedAssets = 1.1e18;

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setMaxExchangeRate(address,uint256,uint256)", sDAI, shares, maxExpectedAssets), controller),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setMaxExchangeRate");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setMaxExchangeRate(sDAI, shares, maxExpectedAssets, controller, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        // maxExchangeRates stores value in 1e36 precision: maxExpectedAssets * 1e18 / shares * 1e18 = 1.1e36
        assertEq(ControllerLike(controller).maxExchangeRates(sDAI), 1.1e36);
    }

    function testSetMaxExchangeRateOnSparkController() public {
        _checkSetMaxExchangeRate(SPARK_CONTROLLER, keccak256("exrS"));
    }

    function testSetMaxExchangeRateOnGroveController() public {
        _checkSetMaxExchangeRate(GROVE_CONTROLLER, keccak256("exrG"));
    }

    // --- setUniswapV3PoolMaxTickDelta (Grove Only) ---

    function testSetUniswapV3PoolMaxTickDeltaOnGroveController() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        bytes32 salt = keccak256("tick");

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setUniswapV3PoolMaxTickDelta(address,uint24)", pool, uint24(1000)), GROVE_CONTROLLER),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setUniswapV3PoolMaxTickDelta");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setUniswapV3PoolMaxTickDelta(pool, 1000, GROVE_CONTROLLER, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        (uint24 swapMaxTickDelta,,,) = ControllerLike(GROVE_CONTROLLER).uniswapV3PoolParams(pool);
        assertEq(swapMaxTickDelta, 1000);
    }

    // --- setUniswapV3AddLiquidityLowerTickBound (Grove Only) ---

    function testSetUniswapV3AddLiquidityLowerTickBoundOnGroveController() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        bytes32 salt = keccak256("lower");

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setUniswapV3AddLiquidityLowerTickBound(address,int24)", pool, int24(-887220)), GROVE_CONTROLLER),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setUniswapV3AddLiquidityLowerTickBound");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setUniswapV3AddLiquidityLowerTickBound(pool, -887220, GROVE_CONTROLLER, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        (, int24 lowerTick,,) = ControllerLike(GROVE_CONTROLLER).uniswapV3PoolParams(pool);
        assertEq(lowerTick, -887220);
    }

    // --- setUniswapV3AddLiquidityUpperTickBound (Grove Only) ---

    function testSetUniswapV3AddLiquidityUpperTickBoundOnGroveController() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        bytes32 salt = keccak256("upper");

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setUniswapV3AddLiquidityUpperTickBound(address,int24)", pool, int24(887220)), GROVE_CONTROLLER),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setUniswapV3AddLiquidityUpperTickBound");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setUniswapV3AddLiquidityUpperTickBound(pool, 887220, GROVE_CONTROLLER, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        (,, int24 upperTick,) = ControllerLike(GROVE_CONTROLLER).uniswapV3PoolParams(pool);
        assertEq(upperTick, 887220);
    }

    // --- setUniswapV3TwapSecondsAgo (Grove Only) ---

    function testSetUniswapV3TwapSecondsAgoOnGroveController() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        bytes32 salt = keccak256("twap");

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setUniswapV3TwapSecondsAgo(address,uint32)", pool, uint32(1800)), GROVE_CONTROLLER),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setUniswapV3TwapSecondsAgo");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setUniswapV3TwapSecondsAgo(pool, 1800, GROVE_CONTROLLER, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        (,,, uint32 twapSecondsAgo) = ControllerLike(GROVE_CONTROLLER).uniswapV3PoolParams(pool);
        assertEq(twapSecondsAgo, 1800);
    }

    // --- setCentrifugeRecipient (Grove Only) ---

    function testSetCentrifugeRecipientOnGroveController() public {
        uint16 centrifugeId = 1;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("centrifuge"))));
        bytes32 salt = keccak256("cent");

        bytes32 expectedId = _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, abi.encodeWithSignature("setCentrifugeRecipient(uint16,bytes32)", centrifugeId, recipient), GROVE_CONTROLLER),
            bytes32(0),
            salt
        );

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit ProposalSubmitted(expectedId, "setCentrifugeRecipient");
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setCentrifugeRecipient(centrifugeId, recipient, GROVE_CONTROLLER, bytes32(0), salt, MIN_DELAY);
        assertEq(id, expectedId);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        assertEq(ControllerLike(GROVE_CONTROLLER).centrifugeRecipients(centrifugeId), recipient);
    }
}
