// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";
import { Configurator, BeamStateLike, RateLimitsLike } from "../src/Configurator.sol";
import { BeamState } from "../src/BeamState.sol";

// Mock TARGET contract implementing RateLimits interface
contract MockTarget {
    RateLimitsLike.RateLimitData public rateLimitData;
    uint256 public currentRateLimit;
    bool public shouldFail;
    bytes public lastCallData;

    function setRateLimitData(
        bytes32,
        uint256 maxAmount,
        uint256 slope,
        uint256 lastAmount,
        uint256 lastUpdated
    ) external {
        rateLimitData = RateLimitsLike.RateLimitData(maxAmount, slope, lastAmount, lastUpdated);
    }

    function setUnlimitedRateLimitData(bytes32) external {
        rateLimitData = RateLimitsLike.RateLimitData(type(uint256).max, 0, type(uint256).max, block.timestamp);
    }

    function getRateLimitData(bytes32) external view returns (RateLimitsLike.RateLimitData memory) {
        return rateLimitData;
    }

    function getCurrentRateLimit(bytes32) external view returns (uint256) {
        return currentRateLimit;
    }

    function setCurrentRateLimit(uint256 _current) external {
        currentRateLimit = _current;
    }

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    // Mock controller function for testing callControllerAction
    function controllerFunction(uint256 value) external returns (uint256) {
        lastCallData = msg.data;
        require(!shouldFail, "MockTarget/controller-function-failed");
        return value * 2;
    }

    fallback() external {
        lastCallData = msg.data;
        require(!shouldFail, "MockTarget/fallback-failed");
    }
}

contract ConfiguratorTest is DssTest {

    Configurator configurator;
    BeamState beamState;
    MockTarget target1;
    MockTarget target2;

    address constant CBEAM1 = address(0xC1);
    address constant CBEAM2 = address(0xC2);
    address constant USER1 = address(0x1);

    event SetRateLimit(address indexed target, bytes32 indexed key, uint256 maxAmount, uint256 slope);

    function setUp() public {
        beamState = new BeamState();
        configurator = new Configurator(address(beamState));

        target1 = new MockTarget();
        target2 = new MockTarget();

        // Setup default configuration
        beamState.setHop(address(0), 86_400); // 1 day global default
        beamState.setMaxChange(address(0), 15 * WAD / 10); // 1.5x global default
    }

    // --- Constructor Tests ---

    function testConstructor() public view {
        assertEq(address(configurator.beamState()), address(beamState), "beamState should be set");
    }

    // --- Helper Functions ---

    function _setupCBeam(address target, address cBeam) internal {
        beamState.addCBeam(cBeam);
        beamState.setCBeamForController(target, cBeam);
        beamState.setCBeamForRateLimits(target, cBeam);
    }

    function _setupRateLimitData(
        MockTarget target,
        bytes32 key,
        uint256 maxAmount,
        uint256 slope,
        uint256 lastAmount,
        uint256 lastUpdated
    ) internal {
        target.setRateLimitData(key, maxAmount, slope, lastAmount, lastUpdated);
        target.setCurrentRateLimit(lastAmount);
    }

    function _setupDefaultRateLimits(bytes32 key, address target, uint256 maxAmount, uint256 slope) internal {
        beamState.addInitRateLimits(key, target, maxAmount, slope);
    }

    // --- Authorization Tests ---

    function testAuthNotAuthorizedCBeam() public {
        bytes32 key = keccak256("test-key");

        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/not-authorized-ratelimits-cBeam");
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 10 * WAD);
    }

    function testAuthWithAuthorizedCBeam() public {
        bytes32 key = keccak256("test-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 400 * WAD, 4 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 400 * WAD, "maxAmount should be updated by authorized cBeam");
    }

    function testAuthCBeamCannotConfigureDifferentTarget() public {
        bytes32 key = keccak256("test-key");
        _setupCBeam(address(target1), CBEAM1);

        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/not-authorized-ratelimits-cBeam");
        configurator.setRateLimit(address(target2), key, 1_000 * WAD, 10 * WAD);
    }

    // --- Safe Rate Limit Changes Tests ---

    function testSetRateLimitDecreasing() public {
        bytes32 key = keccak256("decreasing-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        vm.prank(CBEAM1);
        vm.expectEmit();
        emit SetRateLimit(address(target1), key, 400 * WAD, 4 * WAD);
        configurator.setRateLimit(address(target1), key, 400 * WAD, 4 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 400 * WAD, "maxAmount should decrease immediately");
        assertEq(data.slope, 4 * WAD, "slope should decrease immediately");
    }

    function testSetRateLimitWithinDefaults() public {
        bytes32 key = keccak256("within-defaults-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        // Increase but stay within defaults is safe
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 800 * WAD, 8 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 800 * WAD, "maxAmount should be set within defaults");
        assertEq(data.slope, 8 * WAD, "slope should be set within defaults");
    }

    function testSetRateLimitDecreasingOneParameter() public {
        bytes32 key = keccak256("partial-decrease-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        // Decrease maxAmount, keep slope same - still safe
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 400 * WAD, 5 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 400 * WAD, "maxAmount should decrease");
        assertEq(data.slope, 5 * WAD, "slope should stay same");
    }

    // --- Unsafe Rate Limit Changes Tests ---

    function testSetRateLimitIncreasingTooSoon() public {
        bytes32 key = keccak256("too-soon-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_200 * WAD, 12 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600); // 1 hour hop
        beamState.setMaxChange(address(target1), 15 * WAD / 10); // 1.5x

        vm.warp(block.timestamp + 3_600); // Warp to allow first increase

        // First increase beyond defaults (unsafe, respects maxChange)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_300 * WAD, 13 * WAD); // 1.3x from current

        // Try to increase again immediately (should fail)
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_400 * WAD, 14 * WAD);
    }

    function testSetRateLimitIncreasingAfterHop() public {
        bytes32 key = keccak256("after-hop-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 3_000 * WAD, 30 * WAD);
        _setupRateLimitData(target1, key, 2_000 * WAD, 20 * WAD, 2_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600); // 1 hour hop
        beamState.setMaxChange(address(target1), 15 * WAD / 10); // 1.5x

        vm.warp(block.timestamp + 3_600); // Warp to allow first increase

        // First increase beyond defaults (unsafe, respects maxChange 1.5x)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 3_000 * WAD, 25 * WAD); // Exactly at defaults, 1.5x maxAmount, 1.25x slope

        // Wait for hop period
        vm.warp(block.timestamp + 3_600);

        // Should succeed after hop (respecting maxChange 1.5x from last)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 4_500 * WAD, 37 * WAD); // Exactly 1.5x from 3_000, ~1.48x slope

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 4_500 * WAD, "maxAmount should increase after hop");
        assertEq(data.slope, 37 * WAD, "slope should increase after hop");
    }

    function testSetRateLimitMaxChangeEnforcedMaxAmount() public {
        bytes32 key = keccak256("maxchange-max-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 800 * WAD, 8 * WAD, 800 * WAD, block.timestamp);
        beamState.setHop(address(target1), 1); // Minimal hop delay
        beamState.setMaxChange(address(target1), 15 * WAD / 10); // 1.5x

        vm.warp(block.timestamp + 1); // Warp past hop to allow attempt

        // Try to increase more than maxChange allows (beyond defaults and beyond maxChange)
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/maxChange-maxAmount");
        configurator.setRateLimit(address(target1), key, 1_300 * WAD, 8 * WAD); // 1.625x increase (> 1.5x)
    }

    function testSetRateLimitMaxChangeEnforcedSlope() public {
        bytes32 key = keccak256("maxchange-slope-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_0000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 8 * WAD, 1_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 1); // Minimal hop delay
        beamState.setMaxChange(address(target1), 15 * WAD / 10); // 1.5x

        vm.warp(block.timestamp + 1); // Warp past hop to allow attempt

        // Try to increase slope more than maxChange allows (beyond defaults and beyond maxChange)
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/maxChange-slope");
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 13 * WAD); // 1.625x increase (> 1.5x)
    }

    function testSetRateLimitMaxChangeAtLimit() public {
        bytes32 key = keccak256("maxchange-exact-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_0000 * WAD, 100 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600);
        beamState.setMaxChange(address(target1), 15 * WAD / 10); // 1.5x

        vm.warp(block.timestamp + 3_600);

        // Exactly at maxChange limit should succeed
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_500 * WAD, 15 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 1_500 * WAD, "maxAmount should be at maxChange limit");
        assertEq(data.slope, 15 * WAD, "slope should be at maxChange limit");
    }

    // --- Timestamp Tracking Tests ---

    function testZzzTimestampSetOnIncrease() public {
        bytes32 key = keccak256("zzz-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_0000 * WAD, 100 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);

        uint256 timeBefore = block.timestamp;

        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);

        assertEq(configurator.zzz(address(target1), key), timeBefore, "zzz should be set to current timestamp");
    }

    function testZzzTimestampNotSetOnDecrease() public {
        bytes32 key = keccak256("zzz-decrease-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_0000 * WAD, 100 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);

        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 800 * WAD, 8 * WAD);

        assertEq(configurator.zzz(address(target1), key), 0, "zzz should not be set on decrease");
    }

    function testZzzTimestampUpdatedOnSecondIncrease() public {
        bytes32 key = keccak256("zzz-second-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_0000 * WAD, 100 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600);

        uint256 firstTime = block.timestamp;
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_100 * WAD, 11 * WAD);
        assertEq(configurator.zzz(address(target1), key), firstTime, "zzz should be set to first increase time");

        vm.warp(block.timestamp + 3_600);
        uint256 secondTime = block.timestamp;

        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);
        assertEq(configurator.zzz(address(target1), key), secondTime, "zzz should be updated to second increase time");
    }

    // --- Unlimited Rate Limit Tests ---

    function testSetUnlimitedRateLimit() public {
        bytes32 key = keccak256("unlimited-key");
        _setupCBeam(address(target1), CBEAM1);
        // Set unlimited for specific TARGET
        _setupDefaultRateLimits(key, address(target1), type(uint256).max, 0);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);

        vm.prank(CBEAM1);
        vm.expectEmit();
        emit SetRateLimit(address(target1), key, type(uint256).max, 0);
        configurator.setRateLimit(address(target1), key, type(uint256).max, 0);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, type(uint256).max, "maxAmount should be unlimited");
        assertEq(data.slope, 0, "slope should be 0");
    }

    function testSetUnlimitedFromLimited() public {
        bytes32 key = keccak256("limited-to-unlimited-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);

        // Set defaults that allow unlimited for specific TARGET
        _setupDefaultRateLimits(key, address(target1), type(uint256).max, 0);

        // Any value passed should result in unlimited due to special unlimited check
        vm.prank(CBEAM1);
        vm.expectEmit();
        emit SetRateLimit(address(target1), key, type(uint256).max, 0);
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 10 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, type(uint256).max, "should set unlimited when defaults are unlimited");
        assertEq(data.slope, 0, "slope should be 0 for unlimited");
    }

    // --- LastAmount Capping Tests ---

    function testLastAmountCappedAtMaxAmount() public {
        bytes32 key = keccak256("cap-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 2_000 * WAD, 20 * WAD, 1_500 * WAD, block.timestamp);
        target1.setCurrentRateLimit(1_500 * WAD);

        // Decrease maxAmount below current lastAmount
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 10 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.lastAmount, 1_000 * WAD, "lastAmount should be capped at new maxAmount");
    }

    function testLastAmountPreservedWhenBelowMax() public {
        bytes32 key = keccak256("preserve-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 2_000 * WAD, 20 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 500 * WAD, block.timestamp);
        target1.setCurrentRateLimit(500 * WAD);

        // Increase maxAmount
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_500 * WAD, 15 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.lastAmount, 500 * WAD, "lastAmount should be preserved when below new max");
    }

    // --- Global Default Fallback Tests ---

    function testGlobalDefaultsUsedWhenNoSpecific() public {
        bytes32 key = keccak256("global-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(0), 1_000 * WAD, 10 * WAD); // Global defaults
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        // Should use global defaults
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 900 * WAD, 9 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 900 * WAD, "should work with global defaults 1");
        assertEq(data.slope, 9 * WAD, "should work with global defaults 2");
    }

    function testSpecificDefaultsOverrideGlobal() public {
        bytes32 key = keccak256("specific-override-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(0), 1_000 * WAD, 10 * WAD); // Global
        _setupDefaultRateLimits(key, address(target1), 2_000 * WAD, 20 * WAD); // Specific
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        // Should use TARGET1 specific defaults (higher limits)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_500 * WAD, 15 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 1_500 * WAD, "should work with specific defaults 1");
        assertEq(data.slope, 15 * WAD, "should work with specific defaults 2");
    }

    function testGlobalHopUsedWhenNoSpecific() public {
        bytes32 key = keccak256("global-hop-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 900 * WAD, 9 * WAD, 900 * WAD, block.timestamp);

        // Only global hop set (in setUp)
        assertEq(beamState.hop(address(target1)), 0, "TARGET1 specific hop should be 0");
        assertEq(beamState.getHop(address(target1)), 86_400, "should fallback to global hop");

        vm.warp(block.timestamp + 86_400); // Warp to allow first increase

        // First increase beyond defaults (unsafe)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_100 * WAD, 11 * WAD);

        // Try second increase immediately - should fail due to global hop
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);
    }

    function testGlobalMaxChangeUsedWhenNoSpecific() public {
        bytes32 key = keccak256("global-maxchange-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 900 * WAD, 9 * WAD, 900 * WAD, block.timestamp);

        // Only global maxChange set (in setUp to 1.5x)
        assertEq(beamState.maxChange(address(target1)), 0, "TARGET1 specific maxChange should be 0");
        assertEq(beamState.getMaxChange(address(target1)), 15 * WAD / 10, "should fallback to global maxChange");

        vm.warp(block.timestamp + 86_400); // Wait for hop

        // Try to increase by 1.67x - should fail due to global maxChange of 1.5x (beyond defaults)
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/maxChange-maxAmount");
        configurator.setRateLimit(address(target1), key, 1_500 * WAD, 9 * WAD);
    }

    // --- Controller Action Tests ---

    function testCallControllerAction() public {
        bytes memory data = abi.encodeWithSignature("controllerFunction(uint256)", 42);

        _setupCBeam(address(target1), CBEAM1);
        beamState.addInitControllerActions(data, address(target1));

        vm.prank(CBEAM1);
        bytes memory ret = configurator.callControllerAction(address(target1), data);

        uint256 result = abi.decode(ret, (uint256));
        assertEq(result, 84, "controller function should return 42 * 2");
        assertEq(target1.lastCallData(), data, "correct data should be passed to TARGET");
    }

    function testCallControllerActionNotWhitelisted() public {
        bytes memory data = abi.encodeWithSignature("controllerFunction(uint256)", 42);

        _setupCBeam(address(target1), CBEAM1);
        // Don't whitelist the action

        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/not-valid-data");
        configurator.callControllerAction(address(target1), data);
    }

    function testCallControllerActionNotAuthorized() public {
        bytes memory data = abi.encodeWithSignature("controllerFunction(uint256)", 42);

        beamState.addInitControllerActions(data, address(target1));
        // Don't setup cBeam authorization

        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/not-authorized-controller-cBeam");
        configurator.callControllerAction(address(target1), data);
    }

    function testCallControllerActionGlobalWhitelist() public {
        bytes memory data = abi.encodeWithSignature("controllerFunction(uint256)", 100);

        _setupCBeam(address(target1), CBEAM1);
        _setupCBeam(address(target2), CBEAM1);
        beamState.addInitControllerActions(data, address(0)); // Global whitelist

        // Should work for any TARGET
        vm.prank(CBEAM1);
        bytes memory ret1 = configurator.callControllerAction(address(target1), data);
        assertEq(abi.decode(ret1, (uint256)), 200, "should work with global whitelist for target1");

        vm.prank(CBEAM1);
        bytes memory ret2 = configurator.callControllerAction(address(target2), data);
        assertEq(abi.decode(ret2, (uint256)), 200, "should work with global whitelist for target2");
    }

    function testCallControllerActionFails() public {
        bytes memory data = abi.encodeWithSignature("controllerFunction(uint256)", 42);

        _setupCBeam(address(target1), CBEAM1);
        beamState.addInitControllerActions(data, address(target1));
        target1.setShouldFail(true);

        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/call-failed");
        configurator.callControllerAction(address(target1), data);
    }

    function testCallControllerActionArbitraryData() public {
        bytes memory data = abi.encodeWithSignature("someOtherFunction(address,uint256)", address(this), 999);

        _setupCBeam(address(target1), CBEAM1);
        beamState.addInitControllerActions(data, address(target1));

        vm.prank(CBEAM1);
        configurator.callControllerAction(address(target1), data);

        assertEq(target1.lastCallData(), data, "arbitrary data should be passed correctly");
    }

    // --- Combined functions Tests ---

    function testFullRateLimitWorkflow() public {
        bytes32 key = keccak256("workflow-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 800 * WAD, 8 * WAD, 800 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600);
        beamState.setMaxChange(address(target1), 2 * WAD); // 2x

        vm.warp(block.timestamp + 3_600); // Warp to allow first unsafe increase

        // 1. Decrease limits (safe, immediate)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 700 * WAD, 7 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 700 * WAD, "step 1: decrease should work immediately");

        // 2. Increase limits beyond defaults (unsafe, sets timestamp)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);

        data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 1_200 * WAD, "step 2: first increase should work");
        uint256 firstIncrease = configurator.zzz(address(target1), key);
        assertGt(firstIncrease, 0, "step 2: zzz should be set");

        // 3. Try immediate second increase (should fail)
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_400 * WAD, 14 * WAD);

        // 4. Wait hop period
        vm.warp(block.timestamp + 3_600);

        // 5. Increase again (should work, respecting maxChange)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 2_400 * WAD, 24 * WAD); // Exactly 2x

        data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 2_400 * WAD, "step 5: second increase should work after hop");
        assertEq(data.slope, 24 * WAD, "step 5: slope should increase");

        // 6. Try to exceed maxChange
        vm.warp(block.timestamp + 3_600);
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/maxChange-maxAmount");
        configurator.setRateLimit(address(target1), key, 4_900 * WAD, 24 * WAD); // >2x (2.04x)
    }

    function testMultipleCBeamsMultipleTargets() public {
        bytes32 key = keccak256("multi-key");

        // Setup CBEAM1 for TARGET1
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        // Setup CBEAM2 for TARGET2
        _setupCBeam(address(target2), CBEAM2);
        _setupDefaultRateLimits(key, address(target2), 2_000 * WAD, 20 * WAD);
        _setupRateLimitData(target2, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);

        // CBEAM1 configures TARGET1
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 600 * WAD, 6 * WAD);

        // CBEAM2 configures TARGET2
        vm.prank(CBEAM2);
        configurator.setRateLimit(address(target2), key, 1_200 * WAD, 12 * WAD);

        // Verify independent operation
        RateLimitsLike.RateLimitData memory data1 = target1.getRateLimitData(key);
        RateLimitsLike.RateLimitData memory data2 = target2.getRateLimitData(key);

        assertEq(data1.maxAmount, 600 * WAD, "TARGET1 should have its own limits");
        assertEq(data2.maxAmount, 1_200 * WAD, "TARGET2 should have its own limits");

        // CBEAM1 cannot configure TARGET2
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/not-authorized-ratelimits-cBeam");
        configurator.setRateLimit(address(target2), key, 1_500 * WAD, 15 * WAD);
    }

    function testIncreaseThenDecreaseThenIncrease() public {
        bytes32 key = keccak256("toggle-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 900 * WAD, 9 * WAD, 900 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600);

        vm.warp(block.timestamp + 3_600); // Warp to allow first increase

        // Increase beyond defaults (sets zzz)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_100 * WAD, 11 * WAD);
        uint256 zzzAfterIncrease = configurator.zzz(address(target1), key);
        assertGt(zzzAfterIncrease, 0, "zzz should be set after increase");

        // Decrease (doesn't update zzz for the decrease itself, but allows future increases)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 900 * WAD, 9 * WAD);
        assertEq(configurator.zzz(address(target1), key), zzzAfterIncrease, "zzz should not change on decrease");

        // Immediate increase (within defaults now) should work
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 10 * WAD);

        // Increase beyond defaults should respect hop from first increase
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);

        // After hop, increase should work
        vm.warp(block.timestamp + 3_600);
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 1_200 * WAD, "should be able to increase after hop");
    }

    function testEdgeCaseZeroValues() public {
        bytes32 key = keccak256("zero-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        // Set to zero (should be allowed as it's decreasing)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 0, 0);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 0, "maxAmount can be set to 0");
        assertEq(data.slope, 0, "slope can be set to 0");
    }

    function testDifferentKeysIndependentZzz() public {
        bytes32 key1 = keccak256("key-1");
        bytes32 key2 = keccak256("key-2");

        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key1, address(target1), 1_000 * WAD, 10 * WAD);
        _setupDefaultRateLimits(key2, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key1, 900 * WAD, 9 * WAD, 900 * WAD, block.timestamp);
        _setupRateLimitData(target1, key2, 900 * WAD, 9 * WAD, 900 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600);

        vm.warp(block.timestamp + 3_600); // Warp to allow first increase

        // Increase key1 beyond defaults
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key1, 1_100 * WAD, 11 * WAD);

        // Increase key2 immediately should work (different key)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key2, 1_100 * WAD, 11 * WAD);

        // But can't increase key1 again immediately
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key1, 1_200 * WAD, 12 * WAD);

        assertGt(configurator.zzz(address(target1), key1), 0, "key1 should have zzz set");
        assertGt(configurator.zzz(address(target1), key2), 0, "key2 should have zzz set");
    }
}
