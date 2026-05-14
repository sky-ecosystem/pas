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
import {
    TimelockCalldataGenerator,
    RateLimitConfig,
    IAaveFacet,
    ICCTPFacet,
    ICentrifugeFacet,
    ICurveFacet,
    IERC4626Facet,
    ILayerZeroFacet,
    IOTCBuffer,
    IOTCFacet,
    IUniswapV3Facet,
    IUniswapV4Facet,
    IUSDSFacet
} from "src/timelock/TimelockCalldataGenerator.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { BeamState } from "src/BeamState.sol";
import { Configurator } from "src/Configurator.sol";
import { PASDeploy } from "deploy/PASDeploy.sol";
import { PASInit } from "deploy/PASInit.sol";
import { PASInstance } from "deploy/PASInstance.sol";
import { MockFacetController } from "../mocks/MockFacetController.sol";

interface ControllerLike {
    function rateLimits() external view returns (address);
}

interface RateLimitsLike {
    function grantRole(bytes32 role, address account) external;
    function getRateLimitData(bytes32 key) external view returns (uint256, uint256, uint256, uint256);
}

contract TimelockCalldataGeneratorTest is DssTest {
    // --- Mainnet Addresses (used only for real rate-limiter integration) ---
    // Rate limiter addresses are fetched from the Spark / Grove controllers on mainnet.
    address constant SPARK_CONTROLLER = 0xc9ff605003A1b389980f650e1aEFA1ef25C8eE32;
    address constant SPARK_PROXY      = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;
    address constant GROVE_CONTROLLER = 0xfd9dEA9a8D5B955649579Af482DB7198A392A9F5;
    address constant GROVE_PROXY      = 0x1369f7b2b38c76B6478c0f0E66D94923421891Ba;
    address constant CHAINLOG         = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    uint256 constant MIN_DELAY = 1 days;

    bytes32 constant OZ_DEFAULT_ADMIN_ROLE = bytes32(0);

    DssInstance dss;

    // --- Fetched from controllers ---
    address SPARK_RATE_LIMITS;
    address GROVE_RATE_LIMITS;

    // --- PAS Instance ---
    BeamState                 beamState;
    Configurator              configurator;
    Timelock                  timelock;
    TimelockCalldataGenerator generator;

    // --- Mock diamond-pau controller (stands in for the deployed diamond) ---
    MockFacetController       controller;

    address pauseProxy;
    address coreCouncil;
    address cBeam;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        // Load DssInstance from chainlog
        dss = MCD.loadFromChainlog(CHAINLOG);

        // Fetch rate limits addresses from real controllers (kept for end-to-end rate-limit checks)
        SPARK_RATE_LIMITS = ControllerLike(SPARK_CONTROLLER).rateLimits();
        GROVE_RATE_LIMITS = ControllerLike(GROVE_CONTROLLER).rateLimits();

        coreCouncil = makeAddr("coreCouncil");
        cBeam       = makeAddr("cBeam");

        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");

        PASInstance memory pas = PASDeploy.deploy(address(this), pauseProxy, MIN_DELAY);
        beamState    = BeamState(pas.beamState);
        configurator = Configurator(pas.configurator);
        timelock     = Timelock(payable(pas.timelock));
        generator    = new TimelockCalldataGenerator(pas.timelock, pas.beamState);

        // Mock controller stands in for the future diamond-pau deployment
        controller = new MockFacetController();

        vm.startPrank(pauseProxy);
        PASInit.init(pas, MIN_DELAY, coreCouncil, new address[](0), new address[](0));
        vm.stopPrank();

        // Grant configurator admin role on mainnet rate limiters (real downstream contracts)
        vm.prank(SPARK_PROXY);
        RateLimitsLike(SPARK_RATE_LIMITS).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));

        vm.prank(GROVE_PROXY);
        RateLimitsLike(GROVE_RATE_LIMITS).grantRole(OZ_DEFAULT_ADMIN_ROLE, address(configurator));

        // Onboard controller, rate limiters, and cBeam in BeamState via generator+timelock
        bytes32 id;
        id = _scheduleWithGeneratorData(generator.addController(address(controller), bytes32(0), keccak256("ctrl"), MIN_DELAY));
        _execute(id);
        id = _scheduleWithGeneratorData(generator.addRateLimits(SPARK_RATE_LIMITS, bytes32(0), keccak256("spark-rl"), MIN_DELAY));
        _execute(id);
        id = _scheduleWithGeneratorData(generator.addRateLimits(GROVE_RATE_LIMITS, bytes32(0), keccak256("grove-rl"), MIN_DELAY));
        _execute(id);
        id = _scheduleWithGeneratorData(generator.addCBeam(cBeam, bytes32(0), keccak256("cbeam"), MIN_DELAY));
        _execute(id);

        // Verify generator-driven calls correctly configured BeamState
        assertEq(beamState.controllers(address(controller)), 1, "controller not added");
        assertEq(beamState.rateLimits(SPARK_RATE_LIMITS), 1, "Spark rate limits not added");
        assertEq(beamState.rateLimits(GROVE_RATE_LIMITS), 1, "Grove rate limits not added");
        assertEq(beamState.cBeams(cBeam), 1, "cBeam not added");

        // Link cBeam to controller / rate limiters
        vm.startPrank(coreCouncil);
        beamState.setCBeamForController(address(controller), cBeam);
        beamState.setCBeamForRateLimits(SPARK_RATE_LIMITS, cBeam);
        beamState.setCBeamForRateLimits(GROVE_RATE_LIMITS, cBeam);
        vm.stopPrank();

        // Set hop for rate limiters (required for setRateLimit to work on increases)
        bytes32 hopId;
        hopId = _scheduleWithGeneratorData(generator.setHop(SPARK_RATE_LIMITS, 1 hours, bytes32(0), keccak256("spark-hop"), MIN_DELAY));
        _execute(hopId);
        hopId = _scheduleWithGeneratorData(generator.setHop(GROVE_RATE_LIMITS, 1 hours, bytes32(0), keccak256("grove-hop"), MIN_DELAY));
        _execute(hopId);
    }

    // ============================================================================
    // Helpers
    // ============================================================================

    // Submits the generator-built calldata to the Timelock as coreCouncil (the proposer)
    // via a low-level call, and returns the id of the just-scheduled operation.
    function _scheduleWithGeneratorData(bytes memory data) internal returns (bytes32 id) {
        vm.prank(coreCouncil);
        (bool success, bytes memory ret) = address(timelock).call(data);
        if (!success) {
            if (ret.length > 0) {
                assembly { revert(add(32, ret), mload(ret)) }
            }
            revert("TimelockCalldataGenerator/schedule-call-failed");
        }
        id = timelock.getLastOperationId();
    }

    function _execute(bytes32 id) internal {
        vm.warp(block.timestamp + MIN_DELAY);
        Timelock.Operation memory op = timelock.getOperation(id);
        timelock.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
    }

    function _getControllerAction(bytes32 id) internal view returns (bytes memory data, address controller_) {
        Timelock.Operation memory op = timelock.getOperation(id);
        // Decode payload: selector (4 bytes) || abi.encode(data, controller)
        bytes memory payload = op.payloads[0];
        assembly {
            payload := add(payload, 4)
        }
        (data, controller_) = abi.decode(payload, (bytes, address));
    }

    function _expectedOperationId(bytes memory payload, bytes32 predecessor, bytes32 salt) internal view returns (bytes32) {
        address[] memory targets = new address[](1);
        targets[0] = address(beamState);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        return timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
    }

    function _expectedControllerActionId(bytes memory controllerData, address controller_, bytes32 predecessor, bytes32 salt) internal view returns (bytes32) {
        return _expectedOperationId(
            abi.encodeWithSelector(BeamState.addInitControllerActions.selector, controllerData, controller_),
            predecessor,
            salt
        );
    }

    // Schedules + executes a generator-built controller action and routes it through the
    // configurator to the mock controller. Returns the extracted controller-action data
    // for assertions.
    function _runControllerAction(bytes memory generatorOutput, bytes memory expectedControllerData, bytes32 salt) internal returns (bytes memory data) {
        bytes32 expectedId = _expectedControllerActionId(expectedControllerData, address(controller), bytes32(0), salt);

        bytes32 id = _scheduleWithGeneratorData(generatorOutput);
        assertEq(id, expectedId, "operation id mismatch");

        address ctrlAddr;
        (data, ctrlAddr) = _getControllerAction(id);
        assertEq(ctrlAddr, address(controller), "controller mismatch");
        assertEq(data, expectedControllerData, "controller data mismatch");

        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(address(controller), data);
    }

    // ============================================================================
    // Constructor Test
    // ============================================================================

    function testConstructor() public {
        TimelockCalldataGenerator newGen = new TimelockCalldataGenerator(address(timelock), address(beamState));

        assertEq(address(newGen.timelock()),  address(timelock),  "Timelock set correctly");
        assertEq(address(newGen.beamState()), address(beamState), "BeamState set correctly");
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

        bytes32 id = _scheduleWithGeneratorData(generator.start(bytes32(0), salt, MIN_DELAY));
        assertEq(id, expectedId);
        _execute(id);

        assertFalse(beamState.stopped());
    }

    function testSetHop() public {
        bytes32 salt = keccak256("hop");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.setHop.selector, SPARK_RATE_LIMITS, 3600), bytes32(0), salt);

        bytes32 id = _scheduleWithGeneratorData(generator.setHop(SPARK_RATE_LIMITS, 3600, bytes32(0), salt, MIN_DELAY));
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.getHop(SPARK_RATE_LIMITS), 3600);
    }

    function testSetMaxChange() public {
        bytes32 salt = keccak256("mc");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.setMaxChange.selector, GROVE_RATE_LIMITS, 2e18), bytes32(0), salt);

        bytes32 id = _scheduleWithGeneratorData(generator.setMaxChange(GROVE_RATE_LIMITS, 2e18, bytes32(0), salt, MIN_DELAY));
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.maxChange(GROVE_RATE_LIMITS), 2e18);
    }

    function testAddRateLimits() public {
        address rateLimits = makeAddr("rateLimits");
        bytes32 salt = keccak256("rl");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.addRateLimits.selector, rateLimits), bytes32(0), salt);

        bytes32 id = _scheduleWithGeneratorData(generator.addRateLimits(rateLimits, bytes32(0), salt, MIN_DELAY));
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.rateLimits(rateLimits), 1);
    }

    function testAddController() public {
        address newController = makeAddr("controller");
        bytes32 salt = keccak256("ctrl");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.addController.selector, newController), bytes32(0), salt);

        bytes32 id = _scheduleWithGeneratorData(generator.addController(newController, bytes32(0), salt, MIN_DELAY));
        assertEq(id, expectedId);
        _execute(id);

        assertEq(beamState.controllers(newController), 1);
    }

    function testAddCBeam() public {
        address beam = makeAddr("beam");
        bytes32 salt = keccak256("cbeam");
        bytes32 expectedId = _expectedOperationId(abi.encodeWithSelector(BeamState.addCBeam.selector, beam), bytes32(0), salt);

        bytes32 id = _scheduleWithGeneratorData(generator.addCBeam(beam, bytes32(0), salt, MIN_DELAY));
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

        bytes32 id = _scheduleWithGeneratorData(generator.addInitRateLimits(config, bytes32(0), salt, MIN_DELAY));
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

        bytes32 id = _scheduleWithGeneratorData(generator.batchAddInitRateLimits(configs, bytes32(0), salt, MIN_DELAY));
        assertEq(id, expectedId);
        assertEq(timelock.getOperationsCount(), 1);

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
    // Controller Action Tests (diamond-pau facets via MockFacetController)
    // ============================================================================

    // --- AaveFacet ---

    function testAave_setMaxSlippage() public {
        address aToken = makeAddr("aToken");
        uint256 slippage = 250;
        bytes32 salt = keccak256("aave-slip");

        bytes memory expected = abi.encodeCall(IAaveFacet.setMaxSlippage, (aToken, slippage));
        _runControllerAction(
            generator.aave_setMaxSlippage(aToken, slippage, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.maxSlippageByAddress(aToken), slippage);
    }

    // --- CCTPFacet ---

    function testCctp_setDomainParameters() public {
        uint32 domain = 6;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("cctp-recipient"))));
        uint32 minFeeCapRate = 10;
        uint32 maxFeeCapRate = 100;
        bytes32 salt = keccak256("cctp-dom");

        bytes memory expected = abi.encodeCall(
            ICCTPFacet.setDomainParameters,
            (domain, recipient, minFeeCapRate, maxFeeCapRate)
        );
        _runControllerAction(
            generator.cctp_setDomainParameters(domain, recipient, minFeeCapRate, maxFeeCapRate, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        (bytes32 storedRecipient, uint32 storedMin, uint32 storedMax) = controller.cctpDomains(domain);
        assertEq(storedRecipient, recipient);
        assertEq(storedMin, minFeeCapRate);
        assertEq(storedMax, maxFeeCapRate);
    }

    // --- CentrifugeFacet ---

    function testCentrifuge_setRecipient() public {
        uint16 centrifugeId = 1;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("centrifuge-recipient"))));
        bytes32 salt = keccak256("cent-recipient");

        bytes memory expected = abi.encodeCall(ICentrifugeFacet.setRecipient, (centrifugeId, recipient));
        _runControllerAction(
            generator.centrifuge_setRecipient(centrifugeId, recipient, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.centrifugeRecipients(centrifugeId), recipient);
    }

    // --- CurveFacet ---

    function testCurve_setMaxSlippage() public {
        address pool = makeAddr("curve-pool");
        uint256 slippage = 150;
        bytes32 salt = keccak256("curve-slip");

        bytes memory expected = abi.encodeCall(ICurveFacet.setMaxSlippage, (pool, slippage));
        _runControllerAction(
            generator.curve_setMaxSlippage(pool, slippage, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.maxSlippageByAddress(pool), slippage);
    }

    // --- ERC4626Facet ---

    function testErc4626_setMaxExchangeRate() public {
        address token = makeAddr("sDAI");
        uint256 shares = 1e18;
        uint256 maxExpectedAssets = 1.1e18;
        bytes32 salt = keccak256("4626-rate");

        bytes memory expected = abi.encodeCall(
            IERC4626Facet.setMaxExchangeRate,
            (token, shares, maxExpectedAssets)
        );
        _runControllerAction(
            generator.erc4626_setMaxExchangeRate(token, shares, maxExpectedAssets, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        (uint256 storedShares, uint256 storedAssets) = controller.exchangeRates(token);
        assertEq(storedShares, shares);
        assertEq(storedAssets, maxExpectedAssets);
    }

    // --- LayerZeroFacet ---

    function testLayerZero_setRecipient() public {
        uint32 endpointId = 111;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("lz-recipient"))));
        bytes32 salt = keccak256("lz-recipient");

        bytes memory expected = abi.encodeCall(ILayerZeroFacet.setRecipient, (endpointId, recipient));
        _runControllerAction(
            generator.layerZero_setRecipient(endpointId, recipient, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.layerZeroRecipients(endpointId), recipient);
    }

    // --- OTCBuffer ---

    function testOtcBuffer_approve() public {
        address asset = makeAddr("usdc");
        uint256 allowance = 5_000_000e6;
        bytes32 salt = keccak256("otcbuf-approve");

        bytes memory expected = abi.encodeCall(IOTCBuffer.approve, (asset, allowance));
        _runControllerAction(
            generator.otcBuffer_approve(asset, allowance, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.approvals(asset), allowance);
    }

    // --- OTCFacet ---

    function testOtc_setMaxSlippage() public {
        address exchange = makeAddr("otc-exchange");
        uint256 slippage = 100;
        bytes32 salt = keccak256("otc-slip");

        bytes memory expected = abi.encodeCall(IOTCFacet.setMaxSlippage, (exchange, slippage));
        _runControllerAction(
            generator.otc_setMaxSlippage(exchange, slippage, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.maxSlippageByAddress(exchange), slippage);
    }

    function testOtc_setBuffer() public {
        address exchange = makeAddr("exchange");
        address buffer   = makeAddr("buffer");
        bytes32 salt = keccak256("otc-buf");

        bytes memory expected = abi.encodeCall(IOTCFacet.setBuffer, (exchange, buffer));
        _runControllerAction(
            generator.otc_setBuffer(exchange, buffer, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.buffers(exchange), buffer);
    }

    function testOtc_setRechargeRate() public {
        address exchange = makeAddr("exchange-rr");
        uint256 normalizedRate = 1e18;
        bytes32 salt = keccak256("otc-rr");

        bytes memory expected = abi.encodeCall(IOTCFacet.setRechargeRate, (exchange, normalizedRate));
        _runControllerAction(
            generator.otc_setRechargeRate(exchange, normalizedRate, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.rechargeRates(exchange), normalizedRate);
    }

    // --- UniswapV3Facet ---

    function testUniswapV3_setMaxSlippage() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        uint256 slippage = 50;
        bytes32 salt = keccak256("v3-slip");

        bytes memory expected = abi.encodeCall(IUniswapV3Facet.setMaxSlippage, (pool, slippage));
        _runControllerAction(
            generator.uniswapV3_setMaxSlippage(pool, slippage, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.maxSlippageByAddress(pool), slippage);
    }

    function testUniswapV3_setMaxTickDelta() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        uint24 maxTickDelta = 1000;
        bytes32 salt = keccak256("v3-tickdelta");

        bytes memory expected = abi.encodeCall(IUniswapV3Facet.setMaxTickDelta, (pool, maxTickDelta));
        _runControllerAction(
            generator.uniswapV3_setMaxTickDelta(pool, maxTickDelta, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.maxTickDeltas(pool), maxTickDelta);
    }

    function testUniswapV3_setLiquidityLowerTickBound() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        int24 lowerTickBound = -887220;
        bytes32 salt = keccak256("v3-lower");

        bytes memory expected = abi.encodeCall(IUniswapV3Facet.setLiquidityLowerTickBound, (pool, lowerTickBound));
        _runControllerAction(
            generator.uniswapV3_setLiquidityLowerTickBound(pool, lowerTickBound, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.liquidityLowerTicks(pool), lowerTickBound);
    }

    function testUniswapV3_setLiquidityUpperTickBound() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        int24 upperTickBound = 887220;
        bytes32 salt = keccak256("v3-upper");

        bytes memory expected = abi.encodeCall(IUniswapV3Facet.setLiquidityUpperTickBound, (pool, upperTickBound));
        _runControllerAction(
            generator.uniswapV3_setLiquidityUpperTickBound(pool, upperTickBound, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.liquidityUpperTicks(pool), upperTickBound);
    }

    function testUniswapV3_setTWAPSecondsAgo() public {
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        uint32 twapSecondsAgo = 1800;
        bytes32 salt = keccak256("v3-twap");

        bytes memory expected = abi.encodeCall(IUniswapV3Facet.setTWAPSecondsAgo, (pool, twapSecondsAgo));
        _runControllerAction(
            generator.uniswapV3_setTWAPSecondsAgo(pool, twapSecondsAgo, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.twapSecondsAgos(pool), twapSecondsAgo);
    }

    // --- UniswapV4Facet ---

    function testUniswapV4_setMaxSlippage() public {
        bytes32 poolId = keccak256("v4-pool");
        uint256 slippage = 75;
        bytes32 salt = keccak256("v4-slip");

        bytes memory expected = abi.encodeCall(IUniswapV4Facet.setMaxSlippage, (poolId, slippage));
        _runControllerAction(
            generator.uniswapV4_setMaxSlippage(poolId, slippage, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.maxSlippageByPoolId(poolId), slippage);
    }

    function testUniswapV4_setTickLimits() public {
        bytes32 poolId = keccak256("v4-tick-pool");
        int24 tickLowerMin = -887220;
        int24 tickUpperMax = 887220;
        uint24 maxTickSpacing = 200;
        bytes32 salt = keccak256("v4-tick");

        bytes memory expected = abi.encodeCall(
            IUniswapV4Facet.setTickLimits,
            (poolId, tickLowerMin, tickUpperMax, maxTickSpacing)
        );
        _runControllerAction(
            generator.uniswapV4_setTickLimits(poolId, tickLowerMin, tickUpperMax, maxTickSpacing, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        (int24 storedLower, int24 storedUpper, uint24 storedSpacing) = controller.tickLimits(poolId);
        assertEq(storedLower, tickLowerMin);
        assertEq(storedUpper, tickUpperMax);
        assertEq(storedSpacing, maxTickSpacing);
    }

    // --- USDSFacet ---

    function testUsds_setVault() public {
        address vault = makeAddr("usds-vault");
        bytes32 salt = keccak256("usds-vault");

        bytes memory expected = abi.encodeCall(IUSDSFacet.setVault, (vault));
        _runControllerAction(
            generator.usds_setVault(vault, address(controller), bytes32(0), salt, MIN_DELAY),
            expected,
            salt
        );

        assertEq(controller.vault(), vault);
    }
}
