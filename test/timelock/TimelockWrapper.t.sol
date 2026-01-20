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

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";
import { TimelockWrapper, RateLimitConfig } from "src/timelock/TimelockWrapper.sol";
import { Timelock } from "src/timelock/Timelock.sol";
import { BeamState } from "src/BeamState.sol";
import { Configurator } from "src/Configurator.sol";
import { PASDeploy } from "deploy/PASDeploy.sol";
import { PASInit } from "deploy/PASInit.sol";
import { PASInstance } from "deploy/PASInstance.sol";

interface ControllerLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function RELAYER() external view returns (bytes32);
    function mintRecipients(uint32) external view returns (bytes32);
    function setMintRecipient(uint32 destinationDomain, bytes32 mintRecipient) external;
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
}

interface RateLimitsLike {
    function grantRole(bytes32 role, address account) external;
    function getRateLimitData(bytes32 key) external view returns (uint256, uint256, uint256, uint256);
}

contract TimelockWrapperTest is DssTest {
    // --- Events ---
    event Kiss(address indexed usr);
    event Diss(address indexed usr);

    // --- Mainnet Addresses ---
    // https://github.com/sparkdotfi/spark-address-registry/blob/0a06d13c3e9d36428a6f916ac25528d82154517b/src/Ethereum.sol
    address constant SPARK_CONTROLLER = 0xE52d643B27601D4d2BAB2052f30cf936ed413cec;
    address constant SPARK_PROXY      = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;

    // https://github.com/grove-labs/grove-address-registry/blob/dd625925ab44e89eadce0cb4258e32aae2dfa73e/src/Ethereum.sol
    address constant GROVE_CONTROLLER = 0xfd9dEA9a8D5B955649579Af482DB7198A392A9F5;
    address constant GROVE_PROXY      = 0x1369f7b2b38c76B6478c0f0E66D94923421891Ba;

    uint256 constant FORK_BLOCK = 24250000;
    uint256 constant MIN_DELAY  = 1 days;

    bytes32 constant OZ_DEFAULT_ADMIN_ROLE = bytes32(0);

    // --- Fetched from controllers ---
    address public SPARK_RATE_LIMITS;
    address public GROVE_RATE_LIMITS;

    // --- PAS Instance ---
    BeamState       public beamState;
    Configurator    public configurator;
    Timelock        public timelock;
    TimelockWrapper public wrapper;

    address public coreCouncil;
    address public cBeam;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);

        // Fetch rate limits from controllers
        SPARK_RATE_LIMITS = ControllerLike(SPARK_CONTROLLER).rateLimits();
        GROVE_RATE_LIMITS = ControllerLike(GROVE_CONTROLLER).rateLimits();

        coreCouncil = makeAddr("coreCouncil");
        cBeam       = makeAddr("cBeam");

        PASInstance memory pas = PASDeploy.deploy(address(this), address(this), MIN_DELAY);
        PASInit.init(pas, MIN_DELAY, coreCouncil, new address[](0), new address[](0));

        beamState    = BeamState(pas.beamState);
        configurator = Configurator(pas.configurator);
        timelock     = Timelock(payable(pas.timelock));
        wrapper      = TimelockWrapper(pas.timelockWrapper);

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

    // ============================================================================
    // Authorization Tests
    // ============================================================================

    function testConstructor() public {
        vm.expectEmit(true, false, false, true);
        emit Rely(address(this));
        TimelockWrapper newWrapper = new TimelockWrapper(address(timelock), address(beamState));

        assertEq(address(newWrapper.timelock()), address(timelock), "Timelock set correctly");
        assertEq(address(newWrapper.beamState()), address(beamState), "BeamState set correctly");
        assertEq(newWrapper.wards(address(this)), 1, "Deployer is ward");
    }

    function testAuth() public {
        checkAuth(address(wrapper), "TimelockWrapper");
    }

    function testKissDiss() public {
        address usr = makeAddr("usr");

        assertEq(wrapper.buds(usr), 0);
        vm.expectEmit(true, false, false, true);
        emit Kiss(usr);
        wrapper.kiss(usr);
        assertEq(wrapper.buds(usr), 1);
        vm.expectEmit(true, false, false, true);
        emit Diss(usr);
        wrapper.diss(usr);
        assertEq(wrapper.buds(usr), 0);
    }

    function testAuthModifiers() public {
        bytes4[] memory authedMethods = new bytes4[](2);
        authedMethods[0] = wrapper.kiss.selector;
        authedMethods[1] = wrapper.diss.selector;

        vm.startPrank(address(0xBEEF));
        checkModifier(address(wrapper), "TimelockWrapper/not-authorized", authedMethods);
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
        checkModifier(address(wrapper), "TimelockWrapper/not-whitelisted", tolledMethods);
        vm.stopPrank();
    }

    // ============================================================================
    // BeamState Configuration Tests
    // ============================================================================

    function testStart() public {
        vm.prank(coreCouncil);
        beamState.stop();
        assertTrue(beamState.stopped());

        vm.prank(coreCouncil);
        bytes32 id = wrapper.start(bytes32(0), keccak256("start"), MIN_DELAY);
        _execute(id);

        assertFalse(beamState.stopped());
    }

    function testSetHop() public {
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setHop(SPARK_RATE_LIMITS, 3600, bytes32(0), keccak256("hop"), MIN_DELAY);
        _execute(id);

        assertEq(beamState.getHop(SPARK_RATE_LIMITS), 3600);
    }

    function testSetMaxChange() public {
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setMaxChange(GROVE_RATE_LIMITS, 2e18, bytes32(0), keccak256("mc"), MIN_DELAY);
        _execute(id);

        assertEq(beamState.maxChange(GROVE_RATE_LIMITS), 2e18);
    }

    function testAddRateLimits() public {
        address rateLimits = makeAddr("rateLimits");

        vm.prank(coreCouncil);
        bytes32 id = wrapper.addRateLimits(rateLimits, bytes32(0), keccak256("rl"), MIN_DELAY);
        _execute(id);

        assertEq(beamState.rateLimits(rateLimits), 1);
    }

    function testAddController() public {
        address controller = makeAddr("controller");

        vm.prank(coreCouncil);
        bytes32 id = wrapper.addController(controller, bytes32(0), keccak256("ctrl"), MIN_DELAY);
        _execute(id);

        assertEq(beamState.controllers(controller), 1);
    }

    function testAddCBeam() public {
        address beam = makeAddr("beam");

        vm.prank(coreCouncil);
        bytes32 id = wrapper.addCBeam(beam, bytes32(0), keccak256("cbeam"), MIN_DELAY);
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

        vm.prank(coreCouncil);
        bytes32 id = wrapper.addInitRateLimits(config, bytes32(0), salt, MIN_DELAY);
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

        vm.prank(coreCouncil);
        wrapper.batchAddInitRateLimits(configs, bytes32(0), salt, MIN_DELAY);
        assertEq(timelock.getOperationCount(), 1);

        vm.warp(block.timestamp + MIN_DELAY);
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        for (uint256 i = 0; i < 2; i++) {
            targets[i] = address(beamState);
            payloads[i] = abi.encodeWithSelector(BeamState.addInitRateLimits.selector, configs[i].key, configs[i].rateLimits, configs[i].maxAmount, configs[i].slope);
        }
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
        ControllerLike ctrl = ControllerLike(controller);
        bytes32 role = ctrl.RELAYER();
        address account = makeAddr("relayer");

        assertFalse(ctrl.hasRole(role, account));

        vm.prank(coreCouncil);
        bytes32 id = wrapper.grantRole(controller, role, account, bytes32(0), salt, MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertTrue(ctrl.hasRole(role, account));
    }

    function testGrantRoleOnSparkController() public {
        _checkGrantRole(SPARK_CONTROLLER, keccak256("grantS"));
    }

    function testGrantRoleOnGroveController() public {
        _checkGrantRole(GROVE_CONTROLLER, keccak256("grantG"));
    }

    // --- revokeRole (Spark & Grove) ---

    function _checkRevokeRole(address controller, address admin, bytes32 salt) internal {
        ControllerLike ctrl = ControllerLike(controller);
        bytes32 role = ctrl.RELAYER();
        address account = makeAddr("toRevoke");

        vm.prank(admin);
        ctrl.grantRole(role, account);

        vm.prank(coreCouncil);
        bytes32 id = wrapper.revokeRole(controller, role, account, bytes32(0), salt, MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertFalse(ctrl.hasRole(role, account));
    }

    function testRevokeRoleOnSparkController() public {
        _checkRevokeRole(SPARK_CONTROLLER, SPARK_PROXY, keccak256("revokeS"));
    }

    function testRevokeRoleOnGroveController() public {
        _checkRevokeRole(GROVE_CONTROLLER, GROVE_PROXY, keccak256("revokeG"));
    }

    // --- setMintRecipient (Spark & Grove) ---

    function _checkSetMintRecipient(address controller, bytes32 salt) internal {
        ControllerLike ctrl = ControllerLike(controller);
        uint32 domain = 6;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("recipient"))));

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setMintRecipient(domain, recipient, controller, bytes32(0), salt, MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertEq(ctrl.mintRecipients(domain), recipient);
    }

    function testSetMintRecipientOnSparkController() public {
        _checkSetMintRecipient(SPARK_CONTROLLER, keccak256("mintS"));
    }

    function testSetMintRecipientOnGroveController() public {
        _checkSetMintRecipient(GROVE_CONTROLLER, keccak256("mintG"));
    }

    // --- setLayerZeroRecipient (Spark & Grove) ---

    function _checkSetLayerZeroRecipient(address controller, bytes32 salt) internal {
        ControllerLike ctrl = ControllerLike(controller);
        uint32 endpointId = 111;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("lzRecipient"))));

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setLayerZeroRecipient(endpointId, recipient, controller, bytes32(0), salt, MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertEq(ctrl.layerZeroRecipients(endpointId), recipient);
    }

    function testSetLayerZeroRecipientOnSparkController() public {
        _checkSetLayerZeroRecipient(SPARK_CONTROLLER, keccak256("lzS"));
    }

    function testSetLayerZeroRecipientOnGroveController() public {
        _checkSetLayerZeroRecipient(GROVE_CONTROLLER, keccak256("lzG"));
    }

    // --- setMaxSlippage (Spark & Grove) ---

    function _checkSetMaxSlippage(address controller, bytes32 salt) internal {
        ControllerLike ctrl = ControllerLike(controller);
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
        uint256 slippage = 100;

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setMaxSlippage(pool, slippage, controller, bytes32(0), salt, MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        assertEq(ctrl.maxSlippages(pool), slippage);
    }

    function testSetMaxSlippageOnSparkController() public {
        _checkSetMaxSlippage(SPARK_CONTROLLER, keccak256("slipS"));
    }

    function testSetMaxSlippageOnGroveController() public {
        _checkSetMaxSlippage(GROVE_CONTROLLER, keccak256("slipG"));
    }

    // --- setOTCBuffer (Spark Only) ---

    function testSetOTCBufferOnSparkController() public {
        ControllerLike spark = ControllerLike(SPARK_CONTROLLER);
        address exchange = makeAddr("exchange");
        address buffer = makeAddr("buffer");

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setOTCBuffer(exchange, buffer, SPARK_CONTROLLER, bytes32(0), keccak256("buf"), MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(SPARK_CONTROLLER, data);
        (address setBuffer,,,,) = spark.otcs(exchange);
        assertEq(setBuffer, buffer);
    }

    // --- setOTCRechargeRate (Spark Only) ---

    function testSetOTCRechargeRateOnSparkController() public {
        ControllerLike spark = ControllerLike(SPARK_CONTROLLER);
        address exchange = makeAddr("exchange");

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setOTCRechargeRate(exchange, 1e18, SPARK_CONTROLLER, bytes32(0), keccak256("rate"), MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(SPARK_CONTROLLER, data);
        (, uint256 rechargeRate,,,) = spark.otcs(exchange);
        assertEq(rechargeRate, 1e18);
    }

    // --- setOTCWhitelistedAsset (Spark Only) ---

    function testSetOTCWhitelistedAssetOnSparkController() public {
        ControllerLike spark = ControllerLike(SPARK_CONTROLLER);
        address exchange = makeAddr("exchange");
        address buffer = makeAddr("buffer");
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // First set the buffer (required before whitelisting assets)
        vm.prank(coreCouncil);
        bytes32 bufferId = wrapper.setOTCBuffer(exchange, buffer, SPARK_CONTROLLER, bytes32(0), keccak256("wlbuf"), MIN_DELAY);
        (bytes memory bufferData,) = _getControllerAction(bufferId);
        _execute(bufferId);
        vm.prank(cBeam);
        configurator.callControllerAction(SPARK_CONTROLLER, bufferData);

        // Now whitelist the asset
        vm.prank(coreCouncil);
        bytes32 id = wrapper.setOTCWhitelistedAsset(exchange, usdc, true, SPARK_CONTROLLER, bytes32(0), keccak256("wl"), MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(SPARK_CONTROLLER, data);
        assertTrue(spark.otcWhitelistedAssets(exchange, usdc));
    }

    // --- setMaxExchangeRate (Spark & Grove) ---

    function _checkSetMaxExchangeRate(address controller, bytes32 salt) internal {
        ControllerLike ctrl = ControllerLike(controller);
        address sDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
        uint256 shares = 1e18;
        uint256 maxExpectedAssets = 1.1e18;

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setMaxExchangeRate(sDAI, shares, maxExpectedAssets, controller, bytes32(0), salt, MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(controller, data);
        // maxExchangeRates stores value in 1e36 precision: maxExpectedAssets * 1e18 / shares * 1e18 = 1.1e36
        assertEq(ctrl.maxExchangeRates(sDAI), 1.1e36);
    }

    function testSetMaxExchangeRateOnSparkController() public {
        _checkSetMaxExchangeRate(SPARK_CONTROLLER, keccak256("exrS"));
    }

    function testSetMaxExchangeRateOnGroveController() public {
        _checkSetMaxExchangeRate(GROVE_CONTROLLER, keccak256("exrG"));
    }

    // --- setUniswapV3PoolMaxTickDelta (Grove Only) ---

    function testSetUniswapV3PoolMaxTickDeltaOnGroveController() public {
        ControllerLike grove = ControllerLike(GROVE_CONTROLLER);
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setUniswapV3PoolMaxTickDelta(pool, 1000, GROVE_CONTROLLER, bytes32(0), keccak256("tick"), MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        (uint24 swapMaxTickDelta,,,) = grove.uniswapV3PoolParams(pool);
        assertEq(swapMaxTickDelta, 1000);
    }

    // --- setUniswapV3AddLiquidityLowerTickBound (Grove Only) ---

    function testSetUniswapV3AddLiquidityLowerTickBoundOnGroveController() public {
        ControllerLike grove = ControllerLike(GROVE_CONTROLLER);
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setUniswapV3AddLiquidityLowerTickBound(pool, -887220, GROVE_CONTROLLER, bytes32(0), keccak256("lower"), MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        (, int24 lowerTick,,) = grove.uniswapV3PoolParams(pool);
        assertEq(lowerTick, -887220);
    }

    // --- setUniswapV3AddLiquidityUpperTickBound (Grove Only) ---

    function testSetUniswapV3AddLiquidityUpperTickBoundOnGroveController() public {
        ControllerLike grove = ControllerLike(GROVE_CONTROLLER);
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setUniswapV3AddLiquidityUpperTickBound(pool, 887220, GROVE_CONTROLLER, bytes32(0), keccak256("upper"), MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        (,, int24 upperTick,) = grove.uniswapV3PoolParams(pool);
        assertEq(upperTick, 887220);
    }

    // --- setUniswapV3TwapSecondsAgo (Grove Only) ---

    function testSetUniswapV3TwapSecondsAgoOnGroveController() public {
        ControllerLike grove = ControllerLike(GROVE_CONTROLLER);
        address pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setUniswapV3TwapSecondsAgo(pool, 1800, GROVE_CONTROLLER, bytes32(0), keccak256("twap"), MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        (,,, uint32 twapSecondsAgo) = grove.uniswapV3PoolParams(pool);
        assertEq(twapSecondsAgo, 1800);
    }

    // --- setCentrifugeRecipient (Grove Only) ---

    function testSetCentrifugeRecipientOnGroveController() public {
        ControllerLike grove = ControllerLike(GROVE_CONTROLLER);
        uint16 centrifugeId = 1;
        bytes32 recipient = bytes32(uint256(uint160(makeAddr("centrifuge"))));

        vm.prank(coreCouncil);
        bytes32 id = wrapper.setCentrifugeRecipient(centrifugeId, recipient, GROVE_CONTROLLER, bytes32(0), keccak256("cent"), MIN_DELAY);
        (bytes memory data,) = _getControllerAction(id);
        _execute(id);

        vm.prank(cBeam);
        configurator.callControllerAction(GROVE_CONTROLLER, data);
        assertEq(grove.centrifugeRecipients(centrifugeId), recipient);
    }
}
