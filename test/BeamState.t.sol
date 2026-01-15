// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";
import { BeamState } from "../src/BeamState.sol";

contract BeamStateTest is DssTest {

    BeamState beamState;

    address constant USER1 = address(0x1);
    address constant USER2 = address(0x2);
    address constant CBEAM1 = address(0xC1);
    address constant CBEAM2 = address(0xC2);
    address constant TARGET1 = address(0xA1);
    address constant TARGET2 = address(0xA2);

    event SetUserRole(address indexed who, uint8 indexed role, bool enabled);
    event SetRoleAction(uint8 indexed role, bytes4 sig, bool enabled);
    event Stop();
    event Start();
    event SetHop(address indexed rateLimits, uint256 value);
    event SetMaxChange(address indexed rateLimits, uint256 value);
    event AddRateLimits(address indexed rateLimits_);
    event DelRateLimits(address indexed rateLimits_);
    event AddController(address indexed controller);
    event DelController(address indexed controller);
    event AddCBeam(address indexed cBeam);
    event DelCBeam(address indexed cBeam);
    event SetCBeamForController(address indexed controller, address indexed cBeam);
    event UnsetCBeamForController(address indexed controller, address indexed cBeam);
    event SetCBeamForRateLimits(address indexed rateLimits, address indexed cBeam);
    event UnsetCBeamForRateLimits(address indexed rateLimits, address indexed cBeam);
    event AddInitRateLimits(bytes32 indexed key, address indexed rateLimits, uint256 maxAmount, uint256 slope);
    event DelInitRateLimits(bytes32 indexed key, address indexed rateLimits);
    event AddInitControllerActions(bytes32 indexed key, address indexed rateLimits);
    event DelInitControllerActions(bytes32 indexed key, address indexed rateLimits);

    function setUp() public {
        beamState = new BeamState();
    }

    // --- Constructor & Initialization Tests ---

    function testConstructor() public {
        vm.expectEmit();
        emit Rely(address(this));
        BeamState beamState2 = new BeamState();
        assertEq(beamState2.wards(address(this)), 1, "deployer should be ward");
    }

    // --- Authorization Tests ---

    function testAuth() public {
        checkAuth(address(beamState), "BeamState");
    }

    function testModifiers() public {
        bytes4[] memory authedMethods = new bytes4[](2);
        authedMethods[0] = beamState.setUserRole.selector;
        authedMethods[1] = beamState.setRoleAction.selector;

        vm.startPrank(address(0xBEEF));
        checkModifier(address(beamState), "BeamState/not-authorized", authedMethods);
        vm.stopPrank();
    }

    // --- Role Management Tests ---

    function testSetUserRole() public {
        assertFalse(beamState.hasUserRole(USER1, 0), "USER1 should not have role 0 initially");

        vm.expectEmit();
        emit SetUserRole(USER1, 0, true);
        beamState.setUserRole(USER1, 0, true);

        assertTrue(beamState.hasUserRole(USER1, 0), "USER1 should have role 0 after setting");
    }

    function testSetUserRoleMultiple() public {
        beamState.setUserRole(USER1, 0, true);
        beamState.setUserRole(USER1, 5, true);
        beamState.setUserRole(USER1, 255, true);

        assertTrue(beamState.hasUserRole(USER1, 0), "USER1 should have role 0");
        assertTrue(beamState.hasUserRole(USER1, 5), "USER1 should have role 5");
        assertTrue(beamState.hasUserRole(USER1, 255), "USER1 should have role 255");
        assertFalse(beamState.hasUserRole(USER1, 1), "USER1 should not have role 1");
    }

    function testUnsetUserRole() public {
        beamState.setUserRole(USER1, 0, true);
        assertTrue(beamState.hasUserRole(USER1, 0), "USER1 should have role 0");

        vm.expectEmit();
        emit SetUserRole(USER1, 0, false);
        beamState.setUserRole(USER1, 0, false);

        assertFalse(beamState.hasUserRole(USER1, 0), "USER1 should not have role 0 after unsetting");
    }

    function testSetRoleAction() public {
        bytes4 sig = bytes4(keccak256("testFunction()"));
        assertFalse(beamState.isActionInRole(sig, 0), "action should not be in role 0 initially");

        vm.expectEmit();
        emit SetRoleAction(0, sig, true);
        beamState.setRoleAction(0, sig, true);

        assertTrue(beamState.isActionInRole(sig, 0), "action should be in role 0 after setting");
    }

    function testSetRoleActionMultiple() public {
        bytes4 sig = bytes4(keccak256("testFunction()"));
        beamState.setRoleAction(0, sig, true);
        beamState.setRoleAction(5, sig, true);
        beamState.setRoleAction(255, sig, true);

        assertTrue(beamState.isActionInRole(sig, 0), "action should be in role 0");
        assertTrue(beamState.isActionInRole(sig, 5), "action should be in role 5");
        assertTrue(beamState.isActionInRole(sig, 255), "action should be in role 255");
        assertFalse(beamState.isActionInRole(sig, 1), "action should not be in role 1");
    }

    function testUnsetRoleAction() public {
        bytes4 sig = bytes4(keccak256("testFunction()"));
        beamState.setRoleAction(0, sig, true);
        assertTrue(beamState.isActionInRole(sig, 0), "action should be in role 0");

        vm.expectEmit();
        emit SetRoleAction(0, sig, false);
        beamState.setRoleAction(0, sig, false);

        assertFalse(beamState.isActionInRole(sig, 0), "action should not be in role 0 after unsetting");
    }

    // --- Role-based Authorization Tests ---

    function testRoleAuthWithWard() public {
        // Ward can call without role
        beamState.setHop(TARGET1, 100);
        assertEq(beamState.hop(TARGET1), 100, "hop should be set by ward");
    }

    function testRoleAuthWithRole() public {
        // Set up role
        beamState.setRoleAction(5, beamState.setHop.selector, true);
        beamState.setUserRole(USER1, 5, true);

        // User with role can call
        vm.prank(USER1);
        beamState.setHop(TARGET1, 200);
        assertEq(beamState.hop(TARGET1), 200, "hop should be set by role user");
    }

    function testRoleAuthWithoutRoleOrWard() public {
        vm.prank(USER1);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.setHop(TARGET1, 100);
    }

    function testRoleAuthWithWrongRole() public {
        // Set up role 5 for action
        beamState.setRoleAction(5, beamState.setHop.selector, true);
        // Give user role 3 instead
        beamState.setUserRole(USER1, 3, true);

        vm.prank(USER1);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.setHop(TARGET1, 100);
    }

    // --- Hop Configuration Tests ---

    function testSetHop() public {
        vm.expectEmit();
        emit SetHop(TARGET1, 86_400);
        beamState.setHop(TARGET1, 86_400);

        assertEq(beamState.hop(TARGET1), 86_400, "hop should be set for TARGET1");
        assertEq(beamState.getHop(TARGET1), 86_400, "getHop should return correct value");
    }

    function testSetHopGlobal() public {
        beamState.setHop(address(0), 3_600);
        assertEq(beamState.hop(address(0)), 3_600, "global hop should be set");
        assertEq(beamState.getHop(address(0)), 3_600, "getHop should return global value");
    }

    function testGetHopFallback() public {
        beamState.setHop(address(0), 7_200);

        // TARGET1 has no specific hop, should fallback to global
        assertEq(beamState.hop(TARGET1), 0, "TARGET1 hop storage should be 0");
        assertEq(beamState.getHop(TARGET1), 7_200, "getHop should return global fallback");

        // Set specific hop for TARGET1
        beamState.setHop(TARGET1, 14_400);
        assertEq(beamState.getHop(TARGET1), 14_400, "getHop should return TARGET1 specific value");
    }

    function testSetHopRoleAuth() public {
        beamState.setRoleAction(1, beamState.setHop.selector, true);
        beamState.setUserRole(USER1, 1, true);

        vm.prank(USER1);
        beamState.setHop(TARGET1, 1_000);

        assertEq(beamState.hop(TARGET1), 1_000, "hop should be set by role user");
    }

    // --- MaxChange Configuration Tests ---

    function testSetMaxChange() public {
        vm.expectEmit();
        emit SetMaxChange(TARGET1, 2 * WAD);
        beamState.setMaxChange(TARGET1, 2 * WAD);

        assertEq(beamState.maxChange(TARGET1), 2 * WAD, "maxChange should be set for TARGET1");
        assertEq(beamState.getMaxChange(TARGET1), 2 * WAD, "getMaxChange should return correct value");
    }

    function testSetMaxChangeMinimumWad() public {
        beamState.setMaxChange(TARGET1, WAD);
        assertEq(beamState.maxChange(TARGET1), WAD, "maxChange should be WAD");
    }

    function testSetMaxChangeBelowWad() public {
        vm.expectRevert("BeamState/maxChange-below-1x");
        beamState.setMaxChange(TARGET1, WAD - 1);
    }

    function testSetMaxChangeGlobal() public {
        beamState.setMaxChange(address(0), 15 * WAD / 10); // 1.5x
        assertEq(beamState.maxChange(address(0)), 15 * WAD / 10, "global maxChange should be set");
        assertEq(beamState.getMaxChange(address(0)), 15 * WAD / 10, "getMaxChange should return global value");
    }

    function testGetMaxChangeFallback() public {
        beamState.setMaxChange(address(0), 2 * WAD);

        // TARGET1 has no specific maxChange, should fallback to global
        assertEq(beamState.maxChange(TARGET1), 0, "TARGET1 maxChange storage should be 0");
        assertEq(beamState.getMaxChange(TARGET1), 2 * WAD, "getMaxChange should return global fallback");

        // Set specific maxChange for TARGET1
        beamState.setMaxChange(TARGET1, 3 * WAD);
        assertEq(beamState.getMaxChange(TARGET1), 3 * WAD, "getMaxChange should return TARGET1 specific value");
    }

    function testSetMaxChangeRoleAuth() public {
        beamState.setRoleAction(2, beamState.setMaxChange.selector, true);
        beamState.setUserRole(USER1, 2, true);

        vm.prank(USER1);
        beamState.setMaxChange(TARGET1, 2 * WAD);

        assertEq(beamState.maxChange(TARGET1), 2 * WAD, "maxChange should be set by role user");
    }

    // --- cBeam Management Tests ---

    function testAddCBeam() public {
        assertEq(beamState.cBeams(CBEAM1), 0, "CBEAM1 should not be registered initially");

        vm.expectEmit();
        emit AddCBeam(CBEAM1);
        beamState.addCBeam(CBEAM1);

        assertEq(beamState.cBeams(CBEAM1), 1, "CBEAM1 should be registered");
    }

    function testAddCBeamRoleAuth() public {
        beamState.setRoleAction(3, beamState.addCBeam.selector, true);
        beamState.setUserRole(USER1, 3, true);

        vm.prank(USER1);
        beamState.addCBeam(CBEAM1);

        assertEq(beamState.cBeams(CBEAM1), 1, "CBEAM1 should be registered by role user");
    }

    function testDelCBeam() public {
        beamState.addCBeam(CBEAM1);
        assertEq(beamState.cBeams(CBEAM1), 1, "CBEAM1 should be registered");

        vm.expectEmit();
        emit DelCBeam(CBEAM1);
        beamState.delCBeam(CBEAM1);

        assertEq(beamState.cBeams(CBEAM1), 0, "CBEAM1 should not be registered after delete");
    }

    function testDelCBeamRoleAuth() public {
        beamState.addCBeam(CBEAM1);

        beamState.setRoleAction(3, beamState.delCBeam.selector, true);
        beamState.setUserRole(USER1, 3, true);

        vm.prank(USER1);
        beamState.delCBeam(CBEAM1);

        assertEq(beamState.cBeams(CBEAM1), 0, "CBEAM1 should be deleted by role user");
    }

    // --- RateLimits Management Tests ---

    function testAddRateLimits() public {
        assertEq(beamState.rateLimits(TARGET1), 0, "TARGET1 should not be registered initially");

        vm.expectEmit();
        emit AddRateLimits(TARGET1);
        beamState.addRateLimits(TARGET1);

        assertEq(beamState.rateLimits(TARGET1), 1, "TARGET1 should be registered");
    }

    function testAddRateLimitsRoleAuth() public {
        beamState.setRoleAction(8, beamState.addRateLimits.selector, true);
        beamState.setUserRole(USER1, 8, true);

        vm.prank(USER1);
        beamState.addRateLimits(TARGET1);

        assertEq(beamState.rateLimits(TARGET1), 1, "TARGET1 should be registered by role user");
    }

    function testDelRateLimits() public {
        beamState.addRateLimits(TARGET1);
        assertEq(beamState.rateLimits(TARGET1), 1, "TARGET1 should be registered");

        vm.expectEmit();
        emit DelRateLimits(TARGET1);
        beamState.delRateLimits(TARGET1);

        assertEq(beamState.rateLimits(TARGET1), 0, "TARGET1 should not be registered after delete");
    }

    function testDelRateLimitsRoleAuth() public {
        beamState.addRateLimits(TARGET1);

        beamState.setRoleAction(8, beamState.delRateLimits.selector, true);
        beamState.setUserRole(USER1, 8, true);

        vm.prank(USER1);
        beamState.delRateLimits(TARGET1);

        assertEq(beamState.rateLimits(TARGET1), 0, "TARGET1 should be deleted by role user");
    }

    function testAddRateLimitsMultiple() public {
        beamState.addRateLimits(TARGET1);
        beamState.addRateLimits(TARGET2);

        assertEq(beamState.rateLimits(TARGET1), 1, "TARGET1 should be registered");
        assertEq(beamState.rateLimits(TARGET2), 1, "TARGET2 should be registered");
    }

    // --- Controller Management Tests ---

    function testAddController() public {
        assertEq(beamState.controllers(TARGET1), 0, "TARGET1 should not be registered initially");

        vm.expectEmit();
        emit AddController(TARGET1);
        beamState.addController(TARGET1);

        assertEq(beamState.controllers(TARGET1), 1, "TARGET1 should be registered");
    }

    function testAddControllerRoleAuth() public {
        beamState.setRoleAction(9, beamState.addController.selector, true);
        beamState.setUserRole(USER1, 9, true);

        vm.prank(USER1);
        beamState.addController(TARGET1);

        assertEq(beamState.controllers(TARGET1), 1, "TARGET1 should be registered by role user");
    }

    function testDelController() public {
        beamState.addController(TARGET1);
        assertEq(beamState.controllers(TARGET1), 1, "TARGET1 should be registered");

        vm.expectEmit();
        emit DelController(TARGET1);
        beamState.delController(TARGET1);

        assertEq(beamState.controllers(TARGET1), 0, "TARGET1 should not be registered after delete");
    }

    function testDelControllerRoleAuth() public {
        beamState.addController(TARGET1);

        beamState.setRoleAction(9, beamState.delController.selector, true);
        beamState.setUserRole(USER1, 9, true);

        vm.prank(USER1);
        beamState.delController(TARGET1);

        assertEq(beamState.controllers(TARGET1), 0, "TARGET1 should be deleted by role user");
    }

    function testAddControllerMultiple() public {
        beamState.addController(TARGET1);
        beamState.addController(TARGET2);

        assertEq(beamState.controllers(TARGET1), 1, "TARGET1 should be registered");
        assertEq(beamState.controllers(TARGET2), 1, "TARGET2 should be registered");
    }

    // --- cBeam-RateLimits Mapping Tests ---

    function testSetCBeamForRateLimits() public {
        beamState.addRateLimits(TARGET1);
        beamState.addCBeam(CBEAM1);

        assertEq(beamState.rateLimitsCBeams(TARGET1, CBEAM1), 0, "CBEAM1 should not be authorized for TARGET1 initially");

        vm.expectEmit();
        emit SetCBeamForRateLimits(TARGET1, CBEAM1);
        beamState.setCBeamForRateLimits(TARGET1, CBEAM1);

        assertEq(beamState.rateLimitsCBeams(TARGET1, CBEAM1), 1, "CBEAM1 should be authorized for TARGET1");
    }

    function testSetCBeamForRateLimitsNotExisting() public {
        // Test when rateLimits not registered
        vm.expectRevert("BeamState/not-existing-rateLimits");
        beamState.setCBeamForRateLimits(TARGET1, CBEAM1);

        // Test when rateLimits registered but cBeam not registered
        beamState.addRateLimits(TARGET1);
        vm.expectRevert("BeamState/not-existing-cBeam");
        beamState.setCBeamForRateLimits(TARGET1, CBEAM1);
    }

    function testSetCBeamForRateLimitsRoleAuth() public {
        beamState.addRateLimits(TARGET1);
        beamState.addCBeam(CBEAM1);

        beamState.setRoleAction(4, beamState.setCBeamForRateLimits.selector, true);
        beamState.setUserRole(USER1, 4, true);

        vm.prank(USER1);
        beamState.setCBeamForRateLimits(TARGET1, CBEAM1);

        assertEq(beamState.rateLimitsCBeams(TARGET1, CBEAM1), 1, "CBEAM1 should be set for TARGET1 by role user");
    }

    function testUnsetCBeamForRateLimits() public {
        beamState.addRateLimits(TARGET1);
        beamState.addCBeam(CBEAM1);
        beamState.setCBeamForRateLimits(TARGET1, CBEAM1);
        assertEq(beamState.rateLimitsCBeams(TARGET1, CBEAM1), 1, "CBEAM1 should be authorized for TARGET1");

        vm.expectEmit();
        emit UnsetCBeamForRateLimits(TARGET1, CBEAM1);
        beamState.unsetCBeamForRateLimits(TARGET1, CBEAM1);

        assertEq(beamState.rateLimitsCBeams(TARGET1, CBEAM1), 0, "CBEAM1 should not be authorized for TARGET1 after unset");
    }

    function testUnsetCBeamForRateLimitsRoleAuth() public {
        beamState.addRateLimits(TARGET1);
        beamState.addCBeam(CBEAM1);
        beamState.setCBeamForRateLimits(TARGET1, CBEAM1);

        beamState.setRoleAction(4, beamState.unsetCBeamForRateLimits.selector, true);
        beamState.setUserRole(USER1, 4, true);

        vm.prank(USER1);
        beamState.unsetCBeamForRateLimits(TARGET1, CBEAM1);

        assertEq(beamState.rateLimitsCBeams(TARGET1, CBEAM1), 0, "CBEAM1 should be unset for TARGET1 by role user");
    }

    // --- cBeam-Controller Mapping Tests ---

    function testSetCBeamForController() public {
        beamState.addController(TARGET1);
        beamState.addCBeam(CBEAM1);

        assertEq(beamState.controllersCBeams(TARGET1, CBEAM1), 0, "CBEAM1 should not be authorized for TARGET1 initially");

        vm.expectEmit();
        emit SetCBeamForController(TARGET1, CBEAM1);
        beamState.setCBeamForController(TARGET1, CBEAM1);

        assertEq(beamState.controllersCBeams(TARGET1, CBEAM1), 1, "CBEAM1 should be authorized for TARGET1");
    }

    function testSetCBeamForControllerNotExisting() public {
        // Test when controller not registered
        vm.expectRevert("BeamState/not-existing-controller");
        beamState.setCBeamForController(TARGET1, CBEAM1);

        // Test when controller registered but cBeam not registered
        beamState.addController(TARGET1);
        vm.expectRevert("BeamState/not-existing-cBeam");
        beamState.setCBeamForController(TARGET1, CBEAM1);
    }

    function testSetCBeamForControllerRoleAuth() public {
        beamState.addController(TARGET1);
        beamState.addCBeam(CBEAM1);

        beamState.setRoleAction(4, beamState.setCBeamForController.selector, true);
        beamState.setUserRole(USER1, 4, true);

        vm.prank(USER1);
        beamState.setCBeamForController(TARGET1, CBEAM1);

        assertEq(beamState.controllersCBeams(TARGET1, CBEAM1), 1, "CBEAM1 should be set for TARGET1 by role user");
    }

    function testUnsetCBeamForController() public {
        beamState.addController(TARGET1);
        beamState.addCBeam(CBEAM1);
        beamState.setCBeamForController(TARGET1, CBEAM1);
        assertEq(beamState.controllersCBeams(TARGET1, CBEAM1), 1, "CBEAM1 should be authorized for TARGET1");

        vm.expectEmit();
        emit UnsetCBeamForController(TARGET1, CBEAM1);
        beamState.unsetCBeamForController(TARGET1, CBEAM1);

        assertEq(beamState.controllersCBeams(TARGET1, CBEAM1), 0, "CBEAM1 should not be authorized for TARGET1 after unset");
    }

    function testUnsetCBeamForControllerRoleAuth() public {
        beamState.addController(TARGET1);
        beamState.addCBeam(CBEAM1);
        beamState.setCBeamForController(TARGET1, CBEAM1);

        beamState.setRoleAction(4, beamState.unsetCBeamForController.selector, true);
        beamState.setUserRole(USER1, 4, true);

        vm.prank(USER1);
        beamState.unsetCBeamForController(TARGET1, CBEAM1);

        assertEq(beamState.controllersCBeams(TARGET1, CBEAM1), 0, "CBEAM1 should be unset for TARGET1 by role user");
    }

    // --- Rate Limits Tests ---

    function testAddInitRateLimits() public {
        bytes32 key = keccak256("test-key");

        vm.expectEmit();
        emit AddInitRateLimits(key, TARGET1, 1_000 * WAD, 10 * WAD);
        beamState.addInitRateLimits(key, TARGET1, 1_000 * WAD, 10 * WAD);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 1_000 * WAD, "maxAmount should be set");
        assertEq(limits.slope, 10 * WAD, "slope should be set");
    }

    function testAddInitRateLimitsGlobal() public {
        bytes32 key = keccak256("global-key");

        beamState.addInitRateLimits(key, address(0), 500 * WAD, 5 * WAD);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, address(0));
        assertEq(limits.maxAmount, 500 * WAD, "global maxAmount should be set");
        assertEq(limits.slope, 5 * WAD, "global slope should be set");
    }

    function testGetInitRateLimitsFallback() public {
        bytes32 key = keccak256("fallback-key");

        // Set global default
        beamState.addInitRateLimits(key, address(0), 100 * WAD, 1 * WAD);

        // Get for specific TARGET should return global
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 100 * WAD, "should return global maxAmount");
        assertEq(limits.slope, 1 * WAD, "should return global slope");

        // Set specific for TARGET1
        beamState.addInitRateLimits(key, TARGET1, 200 * WAD, 2 * WAD);

        // Should now return TARGET1 specific
        limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 200 * WAD, "should return TARGET1 specific maxAmount");
        assertEq(limits.slope, 2 * WAD, "should return TARGET1 specific slope");
    }

    function testGetInitRateLimitsPartialFallback() public {
        bytes32 key = keccak256("partial-key");

        // Set global default
        beamState.addInitRateLimits(key, address(0), 100 * WAD, 1 * WAD);

        // Set specific values for TARGET1 (with slope = 0 for unlimited)
        beamState.addInitRateLimits(key, TARGET1, 200 * WAD, 0);

        // Should NOT fallback because maxAmount is non-zero (only falls back when BOTH are 0)
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 200 * WAD, "should return TARGET1 specific maxAmount");
        assertEq(limits.slope, 0, "should return TARGET1 specific slope (unlimited)");

        // Test that fallback only happens when BOTH are zero
        beamState.addInitRateLimits(key, TARGET2, 0, 0);
        limits = beamState.getInitRateLimits(key, TARGET2);
        assertEq(limits.maxAmount, 100 * WAD, "should fallback to global when both are 0");
        assertEq(limits.slope, 1 * WAD, "should fallback to global when both are 0");
    }

    function testAddInitRateLimitsRoleAuth() public {
        bytes32 key = keccak256("auth-key");
        beamState.setRoleAction(5, beamState.addInitRateLimits.selector, true);
        beamState.setUserRole(USER1, 5, true);

        vm.prank(USER1);
        beamState.addInitRateLimits(key, TARGET1, 1_000 * WAD, 10 * WAD);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 1_000 * WAD, "maxAmount should be set by role user");
    }

    function testDelInitRateLimits() public {
        bytes32 key = keccak256("del-key");

        beamState.addInitRateLimits(key, TARGET1, 1_000 * WAD, 10 * WAD);
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 1_000 * WAD, "maxAmount should be set");

        vm.expectEmit();
        emit DelInitRateLimits(key, TARGET1);
        beamState.delInitRateLimits(key, TARGET1);

        limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 0, "maxAmount should be deleted");
        assertEq(limits.slope, 0, "slope should be deleted");
    }

    function testDelInitRateLimitsRoleAuth() public {
        bytes32 key = keccak256("del-auth-key");
        beamState.addInitRateLimits(key, TARGET1, 1_000 * WAD, 10 * WAD);

        beamState.setRoleAction(5, beamState.delInitRateLimits.selector, true);
        beamState.setUserRole(USER1, 5, true);

        vm.prank(USER1);
        beamState.delInitRateLimits(key, TARGET1);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 0, "maxAmount should be deleted by role user");
    }

    // --- Controller Actions Tests ---

    function testAddInitControllerActionsFromBytes() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 expectedKey = keccak256(data);

        vm.expectEmit();
        emit AddInitControllerActions(expectedKey, TARGET1);
        bytes32 returnedKey = beamState.addInitControllerActions(data, TARGET1);

        assertEq(returnedKey, expectedKey, "returned key should match expected");
        assertTrue(beamState.isControllerActionEnabled(expectedKey, TARGET1), "action should be enabled for TARGET1");
    }

    function testAddInitControllerActionsGlobal() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);

        beamState.addInitControllerActions(data, address(0));

        assertTrue(beamState.isControllerActionEnabled(key, address(0)), "action should be enabled globally");
        assertTrue(beamState.isControllerActionEnabled(key, TARGET1), "action should be enabled for any TARGET");
        assertTrue(beamState.isControllerActionEnabled(key, TARGET2), "action should be enabled for any TARGET");
    }

    function testIsControllerActionEnabledSpecificOverGlobal() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);

        beamState.addInitControllerActions(data, TARGET1);

        assertTrue(beamState.isControllerActionEnabled(key, TARGET1), "action should be enabled for TARGET1");
        assertFalse(beamState.isControllerActionEnabled(key, TARGET2), "action should not be enabled for TARGET2");
    }

    function testIsControllerActionEnabledBothGlobalAndSpecific() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);

        beamState.addInitControllerActions(data, address(0));
        beamState.addInitControllerActions(data, TARGET1);

        assertTrue(beamState.isControllerActionEnabled(key, TARGET1), "action should be enabled for TARGET1");
        assertTrue(beamState.isControllerActionEnabled(key, TARGET2), "action should be enabled for TARGET2 via global");
    }

    function testAddInitControllerActionsRoleAuth() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);
        beamState.setRoleAction(6, beamState.addInitControllerActions.selector, true);
        beamState.setUserRole(USER1, 6, true);

        vm.prank(USER1);
        beamState.addInitControllerActions(data, TARGET1);

        assertTrue(beamState.isControllerActionEnabled(key, TARGET1), "action should be enabled by role user");
    }

    function testDelInitControllerActions() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);

        beamState.addInitControllerActions(data, TARGET1);
        assertTrue(beamState.isControllerActionEnabled(key, TARGET1), "action should be enabled");

        vm.expectEmit();
        emit DelInitControllerActions(key, TARGET1);
        beamState.delInitControllerActions(key, TARGET1);

        assertFalse(beamState.isControllerActionEnabled(key, TARGET1), "action should be disabled after delete");
    }

    function testDelInitControllerActionsRoleAuth() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);
        beamState.addInitControllerActions(data, TARGET1);

        beamState.setRoleAction(6, beamState.delInitControllerActions.selector, true);
        beamState.setUserRole(USER1, 6, true);

        vm.prank(USER1);
        beamState.delInitControllerActions(key, TARGET1);

        assertFalse(beamState.isControllerActionEnabled(key, TARGET1), "action should be disabled by role user");
    }

    // --- Combined functions Tests ---

    function testFullRoleBasedWorkflow() public {
        // Setup: Create roles for different operations

        // Role 1: Can set hop
        beamState.setRoleAction(1, beamState.setHop.selector, true);
        // Role 2: Can manage cBeams and rateLimits
        beamState.setRoleAction(2, beamState.addCBeam.selector, true);
        beamState.setRoleAction(2, beamState.addRateLimits.selector, true);
        beamState.setRoleAction(2, beamState.setCBeamForRateLimits.selector, true);
        // Role 3: Can set rate limits
        beamState.setRoleAction(3, beamState.addInitRateLimits.selector, true);

        // Assign roles to users
        beamState.setUserRole(USER1, 1, true);
        beamState.setUserRole(USER2, 2, true);
        beamState.setUserRole(USER2, 3, true); // USER2 has multiple roles

        // USER1 sets hop
        vm.prank(USER1);
        beamState.setHop(TARGET1, 3_600);
        assertEq(beamState.hop(TARGET1), 3_600, "USER1 should be able to set hop");

        // USER2 adds cBeam
        vm.prank(USER2);
        beamState.addCBeam(CBEAM1);
        assertEq(beamState.cBeams(CBEAM1), 1, "USER2 should be able to add cBeam");

        // USER2 adds rateLimits
        vm.prank(USER2);
        beamState.addRateLimits(TARGET1);
        assertEq(beamState.rateLimits(TARGET1), 1, "USER2 should be able to add rateLimits");

        // USER2 sets cBeam for rateLimits
        vm.prank(USER2);
        beamState.setCBeamForRateLimits(TARGET1, CBEAM1);
        assertEq(beamState.rateLimitsCBeams(TARGET1, CBEAM1), 1, "USER2 should be able to set rate limits cBeam for TARGET");

        // USER2 adds rate limits
        bytes32 key = keccak256("integration-key");
        vm.prank(USER2);
        beamState.addInitRateLimits(key, TARGET1, 1_000 * WAD, 10 * WAD);
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, 1_000 * WAD, "USER2 should be able to add rate limits");

        // USER1 cannot add cBeam (wrong role)
        vm.prank(USER1);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.addCBeam(CBEAM2);
    }

    function testMultipleTargetConfiguration() public {
        bytes32 key = keccak256("multi-target-key");

        // Configure different settings for different TARGETs
        beamState.setHop(TARGET1, 1_000);
        beamState.setHop(TARGET2, 2_000);
        beamState.setMaxChange(TARGET1, 2 * WAD);
        beamState.setMaxChange(TARGET2, 3 * WAD);
        beamState.addInitRateLimits(key, TARGET1, 100 * WAD, 1 * WAD);
        beamState.addInitRateLimits(key, TARGET2, 200 * WAD, 2 * WAD);

        // Verify each TARGET has its own configuration
        assertEq(beamState.getHop(TARGET1), 1_000, "TARGET1 hop should be 1_000");
        assertEq(beamState.getHop(TARGET2), 2_000, "TARGET2 hop should be 2_000");
        assertEq(beamState.getMaxChange(TARGET1), 2 * WAD, "TARGET1 maxChange should be 2x");
        assertEq(beamState.getMaxChange(TARGET2), 3 * WAD, "TARGET2 maxChange should be 3x");

        BeamState.DefaultRateLimits memory limits1 = beamState.getInitRateLimits(key, TARGET1);
        BeamState.DefaultRateLimits memory limits2 = beamState.getInitRateLimits(key, TARGET2);
        assertEq(limits1.maxAmount, 100 * WAD, "TARGET1 maxAmount should be 100");
        assertEq(limits2.maxAmount, 200 * WAD, "TARGET2 maxAmount should be 200");
    }

    function testUnlimitedRateLimitConfiguration() public {
        bytes32 key = keccak256("unlimited-key");

        // Set unlimited as global default
        beamState.addInitRateLimits(key, address(0), type(uint256).max, 0);

        // Now set unlimited for specific TARGET (this now works with the fix!)
        beamState.addInitRateLimits(key, TARGET1, type(uint256).max, 0);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, TARGET1);
        assertEq(limits.maxAmount, type(uint256).max, "TARGET1 maxAmount should be unlimited");
        assertEq(limits.slope, 0, "TARGET1 slope should be 0 for unlimited");

        // Test that global unlimited also works for TARGET2 (fallback)
        limits = beamState.getInitRateLimits(key, TARGET2);
        assertEq(limits.maxAmount, type(uint256).max, "TARGET2 should fallback to global unlimited maxAmount");
        assertEq(limits.slope, 0, "TARGET2 should fallback to global slope of 0 for unlimited");
    }

    // --- Stop/Start Tests ---

    function testStop() public {
        assertFalse(beamState.stopped(), "BeamState should not be stopped initially");

        vm.expectEmit();
        emit Stop();
        beamState.stop();

        assertTrue(beamState.stopped(), "BeamState should be stopped after calling stop");
    }

    function testStopRoleAuth() public {
        beamState.setRoleAction(7, beamState.stop.selector, true);
        beamState.setUserRole(USER1, 7, true);

        vm.prank(USER1);
        beamState.stop();

        assertTrue(beamState.stopped(), "BeamState should be stopped by role user");
    }

    function testStopNotAuthorized() public {
        vm.prank(USER1);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.stop();
    }

    function testStart() public {
        beamState.stop();
        assertTrue(beamState.stopped(), "BeamState should be stopped");

        vm.expectEmit();
        emit Start();
        beamState.start();

        assertFalse(beamState.stopped(), "BeamState should not be stopped after calling start");
    }

    function testStartRoleAuth() public {
        beamState.stop();

        beamState.setRoleAction(7, beamState.start.selector, true);
        beamState.setUserRole(USER1, 7, true);

        vm.prank(USER1);
        beamState.start();

        assertFalse(beamState.stopped(), "BeamState should be started by role user");
    }

    function testStartNotAuthorized() public {
        beamState.stop();

        vm.prank(USER1);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.start();
    }

    function testMultipleStopCalls() public {
        beamState.stop();
        assertTrue(beamState.stopped(), "BeamState should be stopped");

        // Calling stop again should not revert
        beamState.stop();
        assertTrue(beamState.stopped(), "BeamState should still be stopped");
    }

    function testMultipleStartCalls() public {
        assertFalse(beamState.stopped(), "BeamState should not be stopped initially");

        // Calling start when not stopped should not revert
        beamState.start();
        assertFalse(beamState.stopped(), "BeamState should still not be stopped");
    }
}
