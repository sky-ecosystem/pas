// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { Timelock }            from "src/timelock/Timelock.sol";
import { BeamState }           from "src/BeamState.sol";
import { DecodeProposals }     from "script/DecodeProposals.s.sol";

/// @dev Smoke test: schedule one operation per BeamState function, then run the
///      script to verify the pretty-printer handles every case without reverting.
///      Run with `forge test --match-test test_decodeAllOperations -vv` to see output.
contract DecodeProposalsPrintTest is Test {

    Timelock        timelock;
    BeamState       beamState;
    DecodeProposals script_;

    address admin      = makeAddr("admin");
    address proposer   = makeAddr("proposer");
    address rateLimits = makeAddr("rateLimits");
    address controller = makeAddr("controller");
    address cBeam_     = makeAddr("cBeam");
    address pool       = makeAddr("pool");
    address user       = makeAddr("user");

    uint256 constant MIN_DELAY = 14 days;

    function setUp() public {
        vm.startPrank(admin);
        timelock  = new Timelock(MIN_DELAY, admin);
        beamState = new BeamState();
        timelock.grantRole(timelock.PROPOSER_ROLE(), proposer);
        vm.stopPrank();

        script_ = new DecodeProposals();
    }

    function _sched(bytes memory payload, bytes32 pred, string memory salt) internal returns (bytes32 id) {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[]   memory p = new bytes[](1);
        t[0] = address(beamState);
        p[0] = payload;
        id = timelock.hashOperationBatch(t, v, p, pred, keccak256(bytes(salt)));
        vm.prank(proposer);
        timelock.scheduleBatch(t, v, p, pred, keccak256(bytes(salt)), MIN_DELAY);
    }

    function test_decodeAllOperations() public {
        // --- Admin functions ---
        _sched(abi.encodeCall(BeamState.rely, (user)),                                          bytes32(0), "rely");
        _sched(abi.encodeCall(BeamState.deny, (user)),                                          bytes32(0), "deny");
        _sched(abi.encodeCall(BeamState.setUserRole, (user, 1, true)),                          bytes32(0), "setUserRole");
        _sched(abi.encodeCall(BeamState.setRoleAction, (1, BeamState.setHop.selector, true)),   bytes32(0), "setRoleAction");

        // --- DELAYED role functions ---
        _sched(abi.encodeCall(BeamState.start, ()),                                             bytes32(0), "start");
        _sched(abi.encodeCall(BeamState.setHop, (rateLimits, 64_800)),                          bytes32(0), "setHop");
        _sched(abi.encodeCall(BeamState.setMaxChange, (rateLimits, 1.25e18)),                   bytes32(0), "setMaxChange");
        _sched(abi.encodeCall(BeamState.addRateLimits, (rateLimits)),                           bytes32(0), "addRL");
        _sched(abi.encodeCall(BeamState.addController, (controller)),                           bytes32(0), "addCtrl");
        _sched(abi.encodeCall(BeamState.addCBeam, (cBeam_)),                                    bytes32(0), "addCBeam");

        // addInitRateLimits: normal + unlimited
        _sched(
            abi.encodeCall(BeamState.addInitRateLimits, (keccak256("LIMIT_DEPOSIT"), rateLimits, 10_000_000e18, 115_740e18)),
            bytes32(0), "irl1"
        );
        _sched(
            abi.encodeCall(BeamState.addInitRateLimits, (keccak256("LIMIT_WITHDRAW"), rateLimits, type(uint256).max, 0)),
            bytes32(0), "irl2"
        );

        // addInitControllerActions: recognized (setMaxSlippage, grantRole) + unrecognized
        _sched(
            abi.encodeCall(BeamState.addInitControllerActions, (
                abi.encodeWithSelector(bytes4(keccak256("setMaxSlippage(address,uint256)")), pool, 0.999e18),
                controller
            )),
            bytes32(0), "ca_slippage"
        );
        _sched(
            abi.encodeCall(BeamState.addInitControllerActions, (
                abi.encodeWithSelector(bytes4(keccak256("grantRole(bytes32,address)")), keccak256("RELAYER"), cBeam_),
                controller
            )),
            bytes32(0), "ca_role"
        );
        _sched(
            abi.encodeCall(BeamState.addInitControllerActions, (
                abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(42)),
                controller
            )),
            bytes32(0), "ca_unknown"
        );

        // --- IMMEDIATE role functions ---
        _sched(abi.encodeCall(BeamState.stop, ()),                                              bytes32(0), "stop");
        _sched(abi.encodeCall(BeamState.delRateLimits, (rateLimits)),                           bytes32(0), "delRL");
        _sched(abi.encodeCall(BeamState.delController, (controller)),                           bytes32(0), "delCtrl");
        _sched(abi.encodeCall(BeamState.delCBeam, (cBeam_)),                                    bytes32(0), "delCBeam");
        _sched(abi.encodeCall(BeamState.setCBeamForRateLimits, (rateLimits, cBeam_)),           bytes32(0), "setCBeamRL");
        _sched(abi.encodeCall(BeamState.unsetCBeamForRateLimits, (rateLimits, cBeam_)),         bytes32(0), "unsetCBeamRL");
        _sched(abi.encodeCall(BeamState.setCBeamForController, (controller, cBeam_)),           bytes32(0), "setCBeamCtrl");
        _sched(abi.encodeCall(BeamState.unsetCBeamForController, (controller, cBeam_)),         bytes32(0), "unsetCBeamCtrl");
        _sched(
            abi.encodeCall(BeamState.delInitRateLimits, (keccak256("LIMIT_DEPOSIT"), rateLimits)),
            bytes32(0), "delIRL"
        );
        _sched(
            abi.encodeCall(BeamState.delInitControllerActions, (keccak256("ACTION_KEY"), controller)),
            bytes32(0), "delICA"
        );

        // --- Predecessor chain (covers predecessor display) ---
        bytes32 id1 = _sched(abi.encodeCall(BeamState.addCBeam, (cBeam_)),          bytes32(0), "chain1");
        bytes32 id2 = _sched(abi.encodeCall(BeamState.addRateLimits, (rateLimits)), id1,        "chain2");
                      _sched(abi.encodeCall(BeamState.setHop, (rateLimits, 3600)),  id2,        "chain3");

        // Warp so the chain shows READY
        vm.warp(block.timestamp + MIN_DELAY);

        vm.setEnv("TIMELOCK", vm.toString(address(timelock)));
        vm.setEnv("OP_ID", vm.toString(bytes32(0)));
        script_.run();
    }
}
