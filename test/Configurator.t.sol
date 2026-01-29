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
import { Configurator, BeamStateLike, RateLimitsLike } from "../src/Configurator.sol";
import { BeamState } from "../src/BeamState.sol";

// Mock TARGET contract implementing RateLimits interface
contract MockTarget {
    mapping(bytes32 key => RateLimitsLike.RateLimitData) public rateLimitData;
    bool public shouldFail;
    bytes public lastCallData;

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function setRateLimitData(
        bytes32 key,
        uint256 maxAmount,
        uint256 slope,
        uint256 lastAmount,
        uint256 lastUpdated
    ) external {
        rateLimitData[key] = RateLimitsLike.RateLimitData(maxAmount, slope, lastAmount, lastUpdated);
    }

    function setUnlimitedRateLimitData(bytes32 key) external {
        rateLimitData[key] = RateLimitsLike.RateLimitData(type(uint256).max, 0, type(uint256).max, block.timestamp);
    }

    function getRateLimitData(bytes32 key) external view returns (RateLimitsLike.RateLimitData memory) {
        return rateLimitData[key];
    }

    // Mimics real RateLimits: regenerates based on slope and elapsed time
    function getCurrentRateLimit(bytes32 key) external view returns (uint256) {
        RateLimitsLike.RateLimitData memory d = rateLimitData[key];
        if (d.maxAmount == type(uint256).max) {
            return type(uint256).max;
        }
        return _min(
            d.slope * (block.timestamp - d.lastUpdated) + d.lastAmount,
            d.maxAmount
        );
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
    event CallControllerAction(address indexed controller, bytes data);

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
        beamState.addController(target);
        beamState.addRateLimits(target);
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
        assertEq(data.slope, 4 * WAD, "slope should be updated by authorized cBeam");
    }

    function testAuthCBeamCannotConfigureDifferentTarget() public {
        bytes32 key = keccak256("test-key");
        _setupCBeam(address(target1), CBEAM1);

        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/not-authorized-ratelimits-cBeam");
        configurator.setRateLimit(address(target2), key, 1_000 * WAD, 10 * WAD);
    }

    // --- Decrease Rate Limit Tests (no hop required) ---

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

        vm.warp(block.timestamp + 86_400); // Any increase requires hop

        // Increase but stay within defaults (ceiling is max of current*maxChange and default)
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

        // Decrease maxAmount, keep slope same - no hop required
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 400 * WAD, 5 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 400 * WAD, "maxAmount should decrease");
        assertEq(data.slope, 5 * WAD, "slope should stay same");
    }

    // --- Increase Rate Limit Tests (hop required) ---

    function testSetRateLimitIncreasingTooSoon() public {
        bytes32 key = keccak256("too-soon-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_200 * WAD, 12 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600); // 1 hour hop
        beamState.setMaxChange(address(target1), 15 * WAD / 10); // 1.5x

        vm.warp(block.timestamp + 3_600); // Warp to allow first increase

        // First increase (respects maxChange ceiling)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_300 * WAD, 13 * WAD); // 1.3x from current

        // Try to increase again immediately (should fail)
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_400 * WAD, 14 * WAD);

        // Fails also if one of the parameters is decreasing
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_400 * WAD, 12 * WAD);
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 14 * WAD);
    }

    function testSetRateLimitIncreasingAfterHop() public {
        bytes32 key = keccak256("after-hop-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 2_000 * WAD, 20 * WAD);
        _setupRateLimitData(target1, key, 2_000 * WAD, 20 * WAD, 2_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600); // 1 hour hop
        beamState.setMaxChange(address(target1), 15 * WAD / 10); // 1.5x

        vm.warp(block.timestamp + 3_600); // Warp to allow first increase

        // First increase (respects maxChange ceiling 1.5x)
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

        // Try to increase more than ceiling allows
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/exceeds-max-amount");
        configurator.setRateLimit(address(target1), key, 1_300 * WAD, 8 * WAD); // 1.625x increase (> 1.5x)
    }

    function testSetRateLimitMaxChangeEnforcedSlope() public {
        bytes32 key = keccak256("maxchange-slope-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 8 * WAD, 1_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 1); // Minimal hop delay
        beamState.setMaxChange(address(target1), 15 * WAD / 10); // 1.5x

        vm.warp(block.timestamp + 1); // Warp past hop to allow attempt

        // Try to increase slope more than ceiling allows
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/exceeds-max-slope");
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 13 * WAD); // 1.625x increase (> 1.5x)
    }

    function testSetRateLimitMaxChangeAtLimit() public {
        bytes32 key = keccak256("maxchange-exact-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 100 * WAD);
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

    function testZzzTimestampNotSetOnDecrease() public {
        bytes32 key = keccak256("zzz-decrease-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 100 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);

        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 800 * WAD, 8 * WAD);

        assertEq(configurator.zzz(address(target1), key), 0, "zzz should not be set on decrease");
    }

    function testZzzTimestampUpdatedOnSecondIncrease() public {
        bytes32 key = keccak256("zzz-second-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 100 * WAD);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600);
        vm.warp(block.timestamp + 3_600);

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

    function testRevertSetLimitedWhenDefaultsUnlimited() public {
        bytes32 key = keccak256("unlimited-revert-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 1_000 * WAD, block.timestamp);

        // Set defaults to unlimited
        _setupDefaultRateLimits(key, address(target1), type(uint256).max, 0);

        // Should revert when passing limited values with unlimited defaults
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/unlimited-incorrect-params");
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 10 * WAD);
    }

    // --- LastAmount Capping Tests ---

    function testLastAmountCappedAtMaxAmount() public {
        bytes32 key = keccak256("cap-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        // Current: maxAmount=2000, slope=20, lastAmount=1500
        // getCurrentRateLimit (no time elapsed) = min(20*0 + 1500, 2000) = 1500
        _setupRateLimitData(target1, key, 2_000 * WAD, 20 * WAD, 1_500 * WAD, block.timestamp);

        // Decrease maxAmount below current rate limit (1500 -> 1000)
        // lastAmount = min(newMaxAmount, currentRateLimit) = min(1000, 1500) = 1000
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 10 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.lastAmount, 1_000 * WAD, "lastAmount should be capped at new maxAmount");
    }

    function testLastAmountPreservedWhenBelowMax() public {
        bytes32 key = keccak256("preserve-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 2_000 * WAD, 20 * WAD);
        // Current: maxAmount=1000, slope=10, lastAmount=100
        // Use small lastAmount so regeneration after hop doesn't hit maxAmount
        _setupRateLimitData(target1, key, 1_000 * WAD, 10 * WAD, 100 * WAD, block.timestamp);
        beamState.setHop(address(target1), 1); // 1 second hop

        vm.warp(block.timestamp + 1); // Minimal warp to satisfy hop
        // After 1s: getCurrentRateLimit = min(10*1 + 100, 1000) = 110 WAD

        // Increase maxAmount to 1500 (above current rate limit of 110)
        // lastAmount = min(newMaxAmount, currentRateLimit) = min(1500, 110) = 110
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_500 * WAD, 15 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.lastAmount, 110 * WAD, "lastAmount should be preserved when below new max");
    }

    // --- Global Default Fallback Tests ---

    function testGlobalDefaultsUsedWhenNoSpecific() public {
        bytes32 key = keccak256("global-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(0), 1_000 * WAD, 10 * WAD); // Global defaults
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        vm.warp(block.timestamp + 86_400); // Any increase requires hop

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

        vm.warp(block.timestamp + 86_400); // Any increase requires hop

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

        // First increase (sets zzz)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_100 * WAD, 11 * WAD);

        // Try second increase immediately - should fail due to hop
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

        // Try to increase by 1.67x - should fail due to global maxChange ceiling of 1.5x
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/exceeds-max-amount");
        configurator.setRateLimit(address(target1), key, 1_500 * WAD, 9 * WAD);
    }

    function testSpecificHopUsedOverGlobal() public {
        bytes32 key = keccak256("specific-hop-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 900 * WAD, 9 * WAD, 900 * WAD, block.timestamp);

        // Set specific hop shorter than global (1 hour vs 1 day)
        beamState.setHop(address(target1), 3_600);

        assertGt(beamState.hop(address(0)), 3_600, "global hop should be greater than 3_600");
        assertEq(beamState.hop(address(target1)), 3_600, "TARGET1 specific hop should be 3600");
        assertEq(beamState.getHop(address(target1)), 3_600, "should use specific hop");

        vm.warp(block.timestamp + 3_600); // Warp to specific hop (shorter than global)

        // First increase (sets zzz)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_100 * WAD, 11 * WAD);

        // Try second increase immediately - should fail due to hop
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);

        // Wait for specific hop period (not the global 86_400)
        vm.warp(block.timestamp + 3_600);

        // Should succeed after specific hop period
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 1_200 * WAD, "maxAmount should increase after specific hop");
        assertEq(data.slope, 12 * WAD, "slope should increase after specific hop");
    }

    function testSpecificMaxChangeUsedOverGlobal() public {
        bytes32 key = keccak256("specific-maxchange-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 900 * WAD, 9 * WAD, 900 * WAD, block.timestamp);

        // Set specific maxChange higher than global (2x vs 1.5x)
        beamState.setMaxChange(address(target1), 2 * WAD);

        assertLt(beamState.maxChange(address(0)), 2 * WAD, "global maxChange should be less than 2x");
        assertEq(beamState.maxChange(address(target1)), 2 * WAD, "TARGET1 specific maxChange should be 2x");
        assertEq(beamState.getMaxChange(address(target1)), 2 * WAD, "should use specific maxChange");

        vm.warp(block.timestamp + 86_400); // Wait for hop

        // Increase by 1.67x - would fail with global 1.5x, but succeeds with specific 2x
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_500 * WAD, 15 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 1_500 * WAD, "should allow 1.67x increase with specific 2x maxChange");
        assertEq(data.slope, 15 * WAD, "should allow 1.67x increase with specific 2x slope");

        vm.warp(block.timestamp + 86_400); // Wait for next hop

        // Try to exceed the specific maxChange (2x) - should fail
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/exceeds-max-amount");
        configurator.setRateLimit(address(target1), key, 3_100 * WAD, 15 * WAD); // >2x from 1500
    }

    // --- Controller Action Tests ---

    function testCallControllerAction() public {
        bytes memory data = abi.encodeWithSignature("controllerFunction(uint256)", 42);

        _setupCBeam(address(target1), CBEAM1);
        beamState.addInitControllerActions(data, address(target1));

        vm.prank(CBEAM1);
        vm.expectEmit();
        emit CallControllerAction(address(target1), data);
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
        vm.expectEmit();
        emit CallControllerAction(address(target1), data);
        bytes memory ret1 = configurator.callControllerAction(address(target1), data);
        assertEq(abi.decode(ret1, (uint256)), 200, "should work with global whitelist for target1");

        vm.prank(CBEAM1);
        vm.expectEmit();
        emit CallControllerAction(address(target2), data);
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

    // --- Combined functions Tests ---

    function testFullRateLimitWorkflow() public {
        bytes32 key = keccak256("workflow-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 800 * WAD, 8 * WAD, 800 * WAD, block.timestamp);
        beamState.setHop(address(target1), 3_600);
        beamState.setMaxChange(address(target1), 2 * WAD); // 2x

        vm.warp(block.timestamp + 3_600); // Warp to allow first increase

        // 1. Decrease limits (immediate, no hop required)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 700 * WAD, 7 * WAD);

        RateLimitsLike.RateLimitData memory data = target1.getRateLimitData(key);
        assertEq(data.maxAmount, 700 * WAD, "step 1: decrease should work immediately");

        // 2. Increase limits (sets zzz timestamp)
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
        vm.expectRevert("Configurator/exceeds-max-amount");
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

        vm.warp(block.timestamp + 86_400); // Any increase requires hop

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

        // Increase, sets zzz
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_100 * WAD, 11 * WAD);
        uint256 zzzAfterIncrease = configurator.zzz(address(target1), key);
        assertGt(zzzAfterIncrease, 0, "zzz should be set after increase");

        // Decrease (doesn't update zzz)
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 900 * WAD, 9 * WAD);
        assertEq(configurator.zzz(address(target1), key), zzzAfterIncrease, "zzz should not change on decrease");

        // Immediate increase doesn't work, requires hop
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 10 * WAD);

        // After hop, increase within defaults should work
        vm.warp(block.timestamp + 3_600);
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 1_000 * WAD, 10 * WAD);

        // Immediate increase should fail (hop just used)
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/increment-too-soon");
        configurator.setRateLimit(address(target1), key, 1_200 * WAD, 12 * WAD);

        // After another hop, increase should work
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

    function testRevertHopNotSet() public {
        bytes32 key = keccak256("hop-not-set-key");
        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        // Clear global hop to simulate hop-not-set scenario
        beamState.setHop(address(0), 0);
        // Ensure no specific hop for target1
        beamState.setHop(address(target1), 0);

        vm.warp(block.timestamp + 86_400); // Warp time (doesn't matter since hop is 0)

        // Try to increase rate limits - should revert
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/hop-not-set");
        configurator.setRateLimit(address(target1), key, 600 * WAD, 6 * WAD);
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

        // Increase key1 (sets zzz for key1)
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

    // --- Stop/Start Tests ---

    function testSetRateLimitStoppedAndAfterRestart() public {
        bytes32 key = keccak256("test-key");

        _setupCBeam(address(target1), CBEAM1);
        _setupDefaultRateLimits(key, address(target1), 1_000 * WAD, 10 * WAD);
        _setupRateLimitData(target1, key, 500 * WAD, 5 * WAD, 500 * WAD, block.timestamp);

        vm.warp(block.timestamp + 86_400); // Any increase requires hop

        // Stop the BeamState
        beamState.stop();

        // Try to set rate limit - should revert
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/stopped");
        configurator.setRateLimit(address(target1), key, 600 * WAD, 6 * WAD);

        // Restart the BeamState
        beamState.start();

        // Now it should work
        vm.prank(CBEAM1);
        configurator.setRateLimit(address(target1), key, 600 * WAD, 6 * WAD);

        RateLimitsLike.RateLimitData memory result = target1.getRateLimitData(key);
        assertEq(result.maxAmount, 600 * WAD, "maxAmount should be updated after restart");
    }

    function testCallControllerActionStoppedAndAfterRestart() public {
        _setupCBeam(address(target1), CBEAM1);

        bytes memory data = abi.encodeWithSignature("controllerFunction(uint256)", 123);
        beamState.addInitControllerActions(data, address(0)); // Global whitelist

        // Stop the BeamState
        beamState.stop();

        // Try to call controller action - should revert
        vm.prank(CBEAM1);
        vm.expectRevert("Configurator/stopped");
        configurator.callControllerAction(address(target1), data);

        // Restart the BeamState
        beamState.start();

        // Now it should work
        vm.prank(CBEAM1);
        bytes memory ret = configurator.callControllerAction(address(target1), data);

        uint256 result = abi.decode(ret, (uint256));
        assertEq(result, 246, "controller function should return 123 * 2");
        assertEq(target1.lastCallData(), data, "correct data should be passed to target");
    }
}
