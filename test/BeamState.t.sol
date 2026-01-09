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
    address constant PAU1 = address(0xA1);
    address constant PAU2 = address(0xA2);

    event SetUserRole(address indexed who, uint8 indexed role, bool enabled);
    event SetRoleAction(uint8 indexed role, bytes4 sig, bool enabled);
    event SetHop(address indexed pau, uint256 value);
    event SetMaxChange(address indexed pau, uint256 value);
    event AddCBeam(address indexed cBeam);
    event DelCBeam(address indexed cBeam);
    event SetCBeamForPau(address indexed pau, address indexed cBeam);
    event UnsetCBeamForPau(address indexed pau, address indexed cBeam);
    event AddInitRateLimits(bytes32 indexed key, address indexed pau, uint256 maxAmount, uint256 slope);
    event DelInitRateLimits(bytes32 indexed key, address indexed pau);
    event AddInitControllerActions(bytes32 indexed key, address indexed pau);
    event DelInitControllerActions(bytes32 indexed key, address indexed pau);

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
        beamState.setHop(PAU1, 100);
        assertEq(beamState.hop(PAU1), 100, "hop should be set by ward");
    }

    function testRoleAuthWithRole() public {
        // Set up role
        beamState.setRoleAction(5, beamState.setHop.selector, true);
        beamState.setUserRole(USER1, 5, true);

        // User with role can call
        vm.prank(USER1);
        beamState.setHop(PAU1, 200);
        assertEq(beamState.hop(PAU1), 200, "hop should be set by role user");
    }

    function testRoleAuthWithoutRoleOrWard() public {
        vm.prank(USER1);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.setHop(PAU1, 100);
    }

    function testRoleAuthWithWrongRole() public {
        // Set up role 5 for action
        beamState.setRoleAction(5, beamState.setHop.selector, true);
        // Give user role 3 instead
        beamState.setUserRole(USER1, 3, true);

        vm.prank(USER1);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.setHop(PAU1, 100);
    }

    // --- Hop Configuration Tests ---

    function testSetHop() public {
        vm.expectEmit();
        emit SetHop(PAU1, 86_400);
        beamState.setHop(PAU1, 86_400);

        assertEq(beamState.hop(PAU1), 86_400, "hop should be set for PAU1");
        assertEq(beamState.getHop(PAU1), 86_400, "getHop should return correct value");
    }

    function testSetHopGlobal() public {
        beamState.setHop(address(0), 3_600);
        assertEq(beamState.hop(address(0)), 3_600, "global hop should be set");
        assertEq(beamState.getHop(address(0)), 3_600, "getHop should return global value");
    }

    function testGetHopFallback() public {
        beamState.setHop(address(0), 7_200);

        // PAU1 has no specific hop, should fallback to global
        assertEq(beamState.hop(PAU1), 0, "PAU1 hop storage should be 0");
        assertEq(beamState.getHop(PAU1), 7_200, "getHop should return global fallback");

        // Set specific hop for PAU1
        beamState.setHop(PAU1, 14_400);
        assertEq(beamState.getHop(PAU1), 14_400, "getHop should return PAU1 specific value");
    }

    function testSetHopRoleAuth() public {
        beamState.setRoleAction(1, beamState.setHop.selector, true);
        beamState.setUserRole(USER1, 1, true);

        vm.prank(USER1);
        beamState.setHop(PAU1, 1_000);

        assertEq(beamState.hop(PAU1), 1_000, "hop should be set by role user");
    }

    // --- MaxChange Configuration Tests ---

    function testSetMaxChange() public {
        vm.expectEmit();
        emit SetMaxChange(PAU1, 2 * WAD);
        beamState.setMaxChange(PAU1, 2 * WAD);

        assertEq(beamState.maxChange(PAU1), 2 * WAD, "maxChange should be set for PAU1");
        assertEq(beamState.getMaxChange(PAU1), 2 * WAD, "getMaxChange should return correct value");
    }

    function testSetMaxChangeMinimumWad() public {
        beamState.setMaxChange(PAU1, WAD);
        assertEq(beamState.maxChange(PAU1), WAD, "maxChange should be WAD");
    }

    function testSetMaxChangeBelowWad() public {
        vm.expectRevert("Configurator/maxChange-below-1x");
        beamState.setMaxChange(PAU1, WAD - 1);
    }

    function testSetMaxChangeGlobal() public {
        beamState.setMaxChange(address(0), 15 * WAD / 10); // 1.5x
        assertEq(beamState.maxChange(address(0)), 15 * WAD / 10, "global maxChange should be set");
        assertEq(beamState.getMaxChange(address(0)), 15 * WAD / 10, "getMaxChange should return global value");
    }

    function testGetMaxChangeFallback() public {
        beamState.setMaxChange(address(0), 2 * WAD);

        // PAU1 has no specific maxChange, should fallback to global
        assertEq(beamState.maxChange(PAU1), 0, "PAU1 maxChange storage should be 0");
        assertEq(beamState.getMaxChange(PAU1), 2 * WAD, "getMaxChange should return global fallback");

        // Set specific maxChange for PAU1
        beamState.setMaxChange(PAU1, 3 * WAD);
        assertEq(beamState.getMaxChange(PAU1), 3 * WAD, "getMaxChange should return PAU1 specific value");
    }

    function testSetMaxChangeRoleAuth() public {
        beamState.setRoleAction(2, beamState.setMaxChange.selector, true);
        beamState.setUserRole(USER1, 2, true);

        vm.prank(USER1);
        beamState.setMaxChange(PAU1, 2 * WAD);

        assertEq(beamState.maxChange(PAU1), 2 * WAD, "maxChange should be set by role user");
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

    // --- cBeam-PAU Mapping Tests ---

    function testSetCBeamForPau() public {
        beamState.addCBeam(CBEAM1);

        assertEq(beamState.pauCBeams(PAU1, CBEAM1), 0, "CBEAM1 should not be authorized for PAU1 initially");

        vm.expectEmit();
        emit SetCBeamForPau(PAU1, CBEAM1);
        beamState.setCBeamForPau(PAU1, CBEAM1);

        assertEq(beamState.pauCBeams(PAU1, CBEAM1), 1, "CBEAM1 should be authorized for PAU1");
    }

    function testSetCBeamForPauNotExisting() public {
        vm.expectRevert("BeamState/not-existing-cBeam");
        beamState.setCBeamForPau(PAU1, CBEAM1);
    }

    function testSetCBeamForPauRoleAuth() public {
        beamState.addCBeam(CBEAM1);

        beamState.setRoleAction(4, beamState.setCBeamForPau.selector, true);
        beamState.setUserRole(USER1, 4, true);

        vm.prank(USER1);
        beamState.setCBeamForPau(PAU1, CBEAM1);

        assertEq(beamState.pauCBeams(PAU1, CBEAM1), 1, "CBEAM1 should be set for PAU1 by role user");
    }

    function testUnsetCBeamForPau() public {
        beamState.addCBeam(CBEAM1);
        beamState.setCBeamForPau(PAU1, CBEAM1);
        assertEq(beamState.pauCBeams(PAU1, CBEAM1), 1, "CBEAM1 should be authorized for PAU1");

        vm.expectEmit();
        emit UnsetCBeamForPau(PAU1, CBEAM1);
        beamState.unsetCBeamForPau(PAU1, CBEAM1);

        assertEq(beamState.pauCBeams(PAU1, CBEAM1), 0, "CBEAM1 should not be authorized for PAU1 after unset");
    }

    function testUnsetCBeamForPauRoleAuth() public {
        beamState.addCBeam(CBEAM1);
        beamState.setCBeamForPau(PAU1, CBEAM1);

        beamState.setRoleAction(4, beamState.unsetCBeamForPau.selector, true);
        beamState.setUserRole(USER1, 4, true);

        vm.prank(USER1);
        beamState.unsetCBeamForPau(PAU1, CBEAM1);

        assertEq(beamState.pauCBeams(PAU1, CBEAM1), 0, "CBEAM1 should be unset for PAU1 by role user");
    }

    // --- Rate Limits Tests ---

    function testAddInitRateLimits() public {
        bytes32 key = keccak256("test-key");

        vm.expectEmit();
        emit AddInitRateLimits(key, PAU1, 1_000 * WAD, 10 * WAD);
        beamState.addInitRateLimits(key, PAU1, 1_000 * WAD, 10 * WAD);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, PAU1);
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

        // Get for specific PAU should return global
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, 100 * WAD, "should return global maxAmount");
        assertEq(limits.slope, 1 * WAD, "should return global slope");

        // Set specific for PAU1
        beamState.addInitRateLimits(key, PAU1, 200 * WAD, 2 * WAD);

        // Should now return PAU1 specific
        limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, 200 * WAD, "should return PAU1 specific maxAmount");
        assertEq(limits.slope, 2 * WAD, "should return PAU1 specific slope");
    }

    function testGetInitRateLimitsPartialFallback() public {
        bytes32 key = keccak256("partial-key");

        // Set global default
        beamState.addInitRateLimits(key, address(0), 100 * WAD, 1 * WAD);

        // Set only maxAmount for PAU1
        beamState.addInitRateLimits(key, PAU1, 200 * WAD, 0);

        // Should fallback to global because slope is 0
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, 100 * WAD, "should fallback to global maxAmount");
        assertEq(limits.slope, 1 * WAD, "should fallback to global slope");
    }

    function testAddInitRateLimitsRoleAuth() public {
        bytes32 key = keccak256("auth-key");
        beamState.setRoleAction(5, beamState.addInitRateLimits.selector, true);
        beamState.setUserRole(USER1, 5, true);

        vm.prank(USER1);
        beamState.addInitRateLimits(key, PAU1, 1_000 * WAD, 10 * WAD);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, 1_000 * WAD, "maxAmount should be set by role user");
    }

    function testDelInitRateLimits() public {
        bytes32 key = keccak256("del-key");

        beamState.addInitRateLimits(key, PAU1, 1_000 * WAD, 10 * WAD);
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, 1_000 * WAD, "maxAmount should be set");

        vm.expectEmit();
        emit DelInitRateLimits(key, PAU1);
        beamState.delInitRateLimits(key, PAU1);

        limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, 0, "maxAmount should be deleted");
        assertEq(limits.slope, 0, "slope should be deleted");
    }

    function testDelInitRateLimitsRoleAuth() public {
        bytes32 key = keccak256("del-auth-key");
        beamState.addInitRateLimits(key, PAU1, 1_000 * WAD, 10 * WAD);

        beamState.setRoleAction(5, beamState.delInitRateLimits.selector, true);
        beamState.setUserRole(USER1, 5, true);

        vm.prank(USER1);
        beamState.delInitRateLimits(key, PAU1);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, 0, "maxAmount should be deleted by role user");
    }

    // --- Controller Actions Tests ---

    function testAddInitControllerActionsFromBytes() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 expectedKey = keccak256(data);

        vm.expectEmit();
        emit AddInitControllerActions(expectedKey, PAU1);
        bytes32 returnedKey = beamState.addInitControllerActions(data, PAU1);

        assertEq(returnedKey, expectedKey, "returned key should match expected");
        assertTrue(beamState.isControllerActionEnabled(expectedKey, PAU1), "action should be enabled for PAU1");
    }

    function testAddInitControllerActionsGlobal() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);

        beamState.addInitControllerActions(data, address(0));

        assertTrue(beamState.isControllerActionEnabled(key, address(0)), "action should be enabled globally");
        assertTrue(beamState.isControllerActionEnabled(key, PAU1), "action should be enabled for any PAU");
        assertTrue(beamState.isControllerActionEnabled(key, PAU2), "action should be enabled for any PAU");
    }

    function testIsControllerActionEnabledSpecificOverGlobal() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);

        beamState.addInitControllerActions(data, PAU1);

        assertTrue(beamState.isControllerActionEnabled(key, PAU1), "action should be enabled for PAU1");
        assertFalse(beamState.isControllerActionEnabled(key, PAU2), "action should not be enabled for PAU2");
    }

    function testIsControllerActionEnabledBothGlobalAndSpecific() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);

        beamState.addInitControllerActions(data, address(0));
        beamState.addInitControllerActions(data, PAU1);

        assertTrue(beamState.isControllerActionEnabled(key, PAU1), "action should be enabled for PAU1");
        assertTrue(beamState.isControllerActionEnabled(key, PAU2), "action should be enabled for PAU2 via global");
    }

    function testAddInitControllerActionsRoleAuth() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);
        beamState.setRoleAction(6, beamState.addInitControllerActions.selector, true);
        beamState.setUserRole(USER1, 6, true);

        vm.prank(USER1);
        beamState.addInitControllerActions(data, PAU1);

        assertTrue(beamState.isControllerActionEnabled(key, PAU1), "action should be enabled by role user");
    }

    function testDelInitControllerActions() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);

        beamState.addInitControllerActions(data, PAU1);
        assertTrue(beamState.isControllerActionEnabled(key, PAU1), "action should be enabled");

        vm.expectEmit();
        emit DelInitControllerActions(key, PAU1);
        beamState.delInitControllerActions(key, PAU1);

        assertFalse(beamState.isControllerActionEnabled(key, PAU1), "action should be disabled after delete");
    }

    function testDelInitControllerActionsRoleAuth() public {
        bytes memory data = abi.encodeWithSignature("testFunction(uint256)", 12345);
        bytes32 key = keccak256(data);
        beamState.addInitControllerActions(data, PAU1);

        beamState.setRoleAction(6, beamState.delInitControllerActions.selector, true);
        beamState.setUserRole(USER1, 6, true);

        vm.prank(USER1);
        beamState.delInitControllerActions(key, PAU1);

        assertFalse(beamState.isControllerActionEnabled(key, PAU1), "action should be disabled by role user");
    }

    // --- Combined functions Tests ---

    function testFullRoleBasedWorkflow() public {
        // Setup: Create roles for different operations
        bytes4 hopSig = beamState.setHop.selector;
        bytes4 cBeamSig = beamState.addCBeam.selector;
        bytes4 limitsSig = beamState.addInitRateLimits.selector;

        // Role 1: Can set hop
        beamState.setRoleAction(1, hopSig, true);
        // Role 2: Can manage cBeams
        beamState.setRoleAction(2, cBeamSig, true);
        beamState.setRoleAction(2, beamState.setCBeamForPau.selector, true);
        // Role 3: Can set rate limits
        beamState.setRoleAction(3, limitsSig, true);

        // Assign roles to users
        beamState.setUserRole(USER1, 1, true);
        beamState.setUserRole(USER2, 2, true);
        beamState.setUserRole(USER2, 3, true); // USER2 has multiple roles

        // USER1 sets hop
        vm.prank(USER1);
        beamState.setHop(PAU1, 3_600);
        assertEq(beamState.hop(PAU1), 3_600, "USER1 should be able to set hop");

        // USER2 adds cBeam
        vm.prank(USER2);
        beamState.addCBeam(CBEAM1);
        assertEq(beamState.cBeams(CBEAM1), 1, "USER2 should be able to add cBeam");

        // USER2 sets cBeam for PAU
        vm.prank(USER2);
        beamState.setCBeamForPau(PAU1, CBEAM1);
        assertEq(beamState.pauCBeams(PAU1, CBEAM1), 1, "USER2 should be able to set cBeam for PAU");

        // USER2 adds rate limits
        bytes32 key = keccak256("integration-key");
        vm.prank(USER2);
        beamState.addInitRateLimits(key, PAU1, 1_000 * WAD, 10 * WAD);
        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, 1_000 * WAD, "USER2 should be able to add rate limits");

        // USER1 cannot add cBeam (wrong role)
        vm.prank(USER1);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.addCBeam(CBEAM2);
    }

    function testMultiplePauConfiguration() public {
        bytes32 key = keccak256("multi-pau-key");

        // Configure different settings for different PAUs
        beamState.setHop(PAU1, 1_000);
        beamState.setHop(PAU2, 2_000);
        beamState.setMaxChange(PAU1, 2 * WAD);
        beamState.setMaxChange(PAU2, 3 * WAD);
        beamState.addInitRateLimits(key, PAU1, 100 * WAD, 1 * WAD);
        beamState.addInitRateLimits(key, PAU2, 200 * WAD, 2 * WAD);

        // Verify each PAU has its own configuration
        assertEq(beamState.getHop(PAU1), 1_000, "PAU1 hop should be 1_000");
        assertEq(beamState.getHop(PAU2), 2_000, "PAU2 hop should be 2_000");
        assertEq(beamState.getMaxChange(PAU1), 2 * WAD, "PAU1 maxChange should be 2x");
        assertEq(beamState.getMaxChange(PAU2), 3 * WAD, "PAU2 maxChange should be 3x");

        BeamState.DefaultRateLimits memory limits1 = beamState.getInitRateLimits(key, PAU1);
        BeamState.DefaultRateLimits memory limits2 = beamState.getInitRateLimits(key, PAU2);
        assertEq(limits1.maxAmount, 100 * WAD, "PAU1 maxAmount should be 100");
        assertEq(limits2.maxAmount, 200 * WAD, "PAU2 maxAmount should be 200");
    }

    function testUnlimitedRateLimitConfiguration() public {
        bytes32 key = keccak256("unlimited-key");

        // Set unlimited as global default first (since getInitRateLimits has fallback logic for slope == 0)
        beamState.addInitRateLimits(key, address(0), type(uint256).max, 0);

        // Now set for specific PAU
        beamState.addInitRateLimits(key, PAU1, type(uint256).max, 1);

        BeamState.DefaultRateLimits memory limits = beamState.getInitRateLimits(key, PAU1);
        assertEq(limits.maxAmount, type(uint256).max, "maxAmount should be unlimited");
        assertEq(limits.slope, 1, "slope should be 1");

        // Test that global unlimited also works
        limits = beamState.getInitRateLimits(key, PAU2);
        assertEq(limits.maxAmount, type(uint256).max, "global maxAmount should be unlimited");
        assertEq(limits.slope, 0, "global slope should be 0 for unlimited");
    }
}
