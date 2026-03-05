// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import { BeamState } from "src/BeamState.sol";

// --- Timelock interface ---

interface TimelockLike {
    struct Operation {
        address[] targets;
        uint256[] values;
        bytes[]   payloads;
        bytes32   predecessor;
        bytes32   salt;
    }

    function getOperation(bytes32)        external view returns (Operation memory);
    function getOperationsCount()         external view returns (uint256);
    function getFirstOperationId()        external view returns (bytes32);
    function getNextOperationId(bytes32)  external view returns (bytes32);
    function getTimestamp(bytes32)         external view returns (uint256);
    function isOperationPending(bytes32)  external view returns (bool);
    function isOperationReady(bytes32)    external view returns (bool);
    function isOperationDone(bytes32)     external view returns (bool);
}

// --- Selector-only interface (not for calling, only for .selector computation) ---

interface ControllerSel {
    function grantRole(bytes32, address) external;
    function revokeRole(bytes32, address) external;
    function setMintRecipient(uint32, bytes32) external;
    function setLayerZeroRecipient(uint32, bytes32) external;
    function setMaxSlippage(address, uint256) external;
    function setMaxExchangeRate(address, uint256, uint256) external;
    function setOTCBuffer(address, address) external;
    function setOTCRechargeRate(address, uint256) external;
    function setOTCWhitelistedAsset(address, address, bool) external;
    function setUniswapV4TickLimits(bytes32, int24, int24, uint24) external;
    function setUniswapV3PoolMaxTickDelta(address, uint24) external;
    function setUniswapV3AddLiquidityLowerTickBound(address, int24) external;
    function setUniswapV3AddLiquidityUpperTickBound(address, int24) external;
    function setUniswapV3TwapSecondsAgo(address, uint32) external;
    function setCentrifugeRecipient(uint16, bytes32) external;
    function setMerklDistributor(address) external;
}

/// @title DecodeProposals
/// @notice Forge script for decoding and pretty-printing PAS Timelock proposals.
///         All decoding and formatting logic lives in this single file.
///
/// Usage:
///   # Decode all operations
///   TIMELOCK=0x... forge script script/DecodeProposals.s.sol --fork-url $RPC_URL
///
///   # Decode a specific operation by ID
///   TIMELOCK=0x... OP_ID=0x... forge script script/DecodeProposals.s.sol --fork-url $RPC_URL
///
/// Validating unrecognized controller actions:
///   When a controller action was submitted without the wrapper, the inner calldata
///   is printed as a raw hex blob (the "Data:" field). To verify it matches what you
///   expect, encode the expected call and compare:
///
///     bytes memory expected = abi.encodeWithSelector(
///         Controller.setMaxSlippage.selector, pool, 0.999e18
///     );
///
///   If the hex output matches `vm.toString(expected)`, the proposal is correct.
contract DecodeProposals is Script {

    string constant SEP = "================================================================================";

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() public {
        TimelockLike timelock = TimelockLike(vm.envAddress("TIMELOCK"));
        bytes32 opId = vm.envOr("OP_ID", bytes32(0));

        if (opId != bytes32(0)) {
            console.log("");
            console.log(SEP);
            console.log("  OPERATION %s", vm.toString(opId));
            console.log(SEP);
            _printOperation(timelock, opId, 1, 1);
            console.log("");
            console.log(SEP);
        } else {
            uint256 total = timelock.getOperationsCount();
            if (total == 0) {
                console.log("");
                console.log("  No operations.");
                console.log("");
                return;
            }

            console.log("");
            console.log(SEP);
            console.log("  ALL OPERATIONS (%s)", vm.toString(total));
            console.log(SEP);

            bytes32 id = timelock.getFirstOperationId();
            for (uint256 i; id != bytes32(0); ++i) {
                _printOperation(timelock, id, i + 1, total);
                id = timelock.getNextOperationId(id);
            }
            console.log("");
            console.log(SEP);
        }
    }

    // -------------------------------------------------------------------------
    // Operation printing
    // -------------------------------------------------------------------------

    function _printOperation(TimelockLike timelock, bytes32 id, uint256 idx, uint256 total) internal view {
        TimelockLike.Operation memory op = timelock.getOperation(id);

        bool pending = timelock.isOperationPending(id);
        bool ready   = timelock.isOperationReady(id);
        bool done    = timelock.isOperationDone(id);
        uint256 eta  = timelock.getTimestamp(id);

        string memory status = done ? "DONE" : ready ? "READY  ** executable now **" : pending ? "PENDING" : "NOT FOUND";

        console.log("");
        console.log("--- Operation %s/%s ---", vm.toString(idx), vm.toString(total));
        console.log("  ID:          %s", vm.toString(id));
        console.log("  Status:      %s", status);
        console.log("  ETA:         %s", _fmtEta(eta));
        console.log("  Predecessor: %s", op.predecessor == bytes32(0) ? "none" : vm.toString(op.predecessor));
        console.log("  Salt:        %s", vm.toString(op.salt));
        console.log("  Calls:       %s", vm.toString(op.targets.length));

        for (uint256 i; i < op.targets.length; ++i) {
            _printCall(op.targets[i], op.values[i], op.payloads[i], i + 1, op.targets.length);
        }
    }

    // -------------------------------------------------------------------------
    // Call printing — outer layer (BeamState)
    // -------------------------------------------------------------------------

    function _printCall(
        address target,
        uint256 value,
        bytes memory payload,
        uint256 idx,
        uint256 total
    ) internal view {
        console.log("");
        console.log("  [Call %s/%s]", vm.toString(idx), vm.toString(total));
        console.log("    Target:   %s", vm.toString(target));

        if (value > 0) console.log("    Value:    %s", vm.toString(value));

        require(payload.length >= 4, string.concat(
            "DecodeProposals/payload-too-short: ", vm.toString(payload)
        ));

        bytes4 sel = bytes4(payload);
        string memory name = _beamStateName(sel);
        bytes memory p = _stripSelector(payload);

        require(keccak256(bytes(name)) != keccak256(bytes("unknown")), string.concat(
            "DecodeProposals/unknown-BeamState-selector: ", vm.toString(sel)
        ));

        console.log("    Function: %s (%s)", name, vm.toString(sel));

        // --- No params ---
        if (sel == BeamState.start.selector || sel == BeamState.stop.selector) return;

        // --- Single address: rely, deny, add/del RateLimits/Controller/CBeam ---
        if (sel == BeamState.rely.selector              || sel == BeamState.deny.selector             ||
            sel == BeamState.addRateLimits.selector      || sel == BeamState.delRateLimits.selector    ||
            sel == BeamState.addController.selector      || sel == BeamState.delController.selector    ||
            sel == BeamState.addCBeam.selector            || sel == BeamState.delCBeam.selector)
        {
            console.log("      addr:         %s", vm.toString(abi.decode(p, (address))));
            return;
        }

        // --- setHop(address, uint256) ---
        if (sel == BeamState.setHop.selector) {
            (address a, uint256 v) = abi.decode(p, (address, uint256));
            console.log("      rateLimits:   %s", vm.toString(a));
            console.log("      hop:          %s seconds (%s)", vm.toString(v), _fmtDuration(v));
            return;
        }

        // --- setMaxChange(address, uint256) ---
        if (sel == BeamState.setMaxChange.selector) {
            (address a, uint256 v) = abi.decode(p, (address, uint256));
            console.log("      rateLimits:   %s", vm.toString(a));
            console.log("      maxChange:    %s%s", vm.toString(v), _fmtWadPct(v));
            return;
        }

        // --- set/unsetCBeamForRateLimits(address, address) ---
        if (sel == BeamState.setCBeamForRateLimits.selector || sel == BeamState.unsetCBeamForRateLimits.selector) {
            (address a, address b) = abi.decode(p, (address, address));
            console.log("      rateLimits:   %s", vm.toString(a));
            console.log("      cBeam:        %s", vm.toString(b));
            return;
        }

        // --- set/unsetCBeamForController(address, address) ---
        if (sel == BeamState.setCBeamForController.selector || sel == BeamState.unsetCBeamForController.selector) {
            (address a, address b) = abi.decode(p, (address, address));
            console.log("      controller:   %s", vm.toString(a));
            console.log("      cBeam:        %s", vm.toString(b));
            return;
        }

        // --- addInitRateLimits(bytes32, address, uint256, uint256) ---
        if (sel == BeamState.addInitRateLimits.selector) {
            (bytes32 k, address a, uint256 m, uint256 s) = abi.decode(p, (bytes32, address, uint256, uint256));
            console.log("      key:          %s", vm.toString(k));
            console.log("      rateLimits:   %s", vm.toString(a));
            console.log("      maxAmount:    %s", _fmtAmount(m));
            console.log("      slope:        %s", _fmtAmount(s));
            return;
        }

        // --- delInitRateLimits / delInitControllerActions (bytes32, address) ---
        if (sel == BeamState.delInitRateLimits.selector || sel == BeamState.delInitControllerActions.selector) {
            (bytes32 k, address a) = abi.decode(p, (bytes32, address));
            console.log("      key:          %s", vm.toString(k));
            console.log("      addr:         %s", vm.toString(a));
            return;
        }

        // --- addInitControllerActions(bytes, address) -> nested controller call ---
        if (sel == BeamState.addInitControllerActions.selector) {
            (bytes memory innerData, address controller) = abi.decode(p, (bytes, address));
            _printControllerAction(controller, innerData);
            return;
        }

        // --- setUserRole(address, uint8, bool) ---
        if (sel == BeamState.setUserRole.selector) {
            (address w, uint8 r, bool e) = abi.decode(p, (address, uint8, bool));
            console.log("      who:          %s", vm.toString(w));
            console.log("      role:         %s", vm.toString(uint256(r)));
            console.log("      enabled:      %s", e ? "true" : "false");
            return;
        }

        // --- setRoleAction(uint8, bytes4, bool) ---
        if (sel == BeamState.setRoleAction.selector) {
            (uint8 r, bytes4 sig, bool e) = abi.decode(p, (uint8, bytes4, bool));
            console.log("      role:         %s", vm.toString(uint256(r)));
            console.log("      sig:          %s", vm.toString(sig));
            console.log("      enabled:      %s", e ? "true" : "false");
            return;
        }

        // All known selectors handled above — should never reach here
        revert(string.concat("DecodeProposals/unhandled-selector: ", vm.toString(sel)));
    }

    // -------------------------------------------------------------------------
    // Call printing — inner layer (Controller actions)
    // -------------------------------------------------------------------------

    function _printControllerAction(address controller, bytes memory data) internal view {
        console.log("");
        console.log("      >>> Nested Controller Action");
        console.log("      Controller: %s", vm.toString(controller));

        if (data.length < 4) {
            console.log("      Data:       %s", vm.toString(data));
            return;
        }

        bytes4 sel = bytes4(data);
        string memory name = _controllerName(sel);
        bytes memory p = _stripSelector(data);

        // Unrecognized selector — print raw data for manual comparison
        if (keccak256(bytes(name)) == keccak256(bytes("unknown"))) {
            console.log("      Data:       %s", vm.toString(data));
            return;
        }

        console.log("      Function:   %s (%s)", name, vm.toString(sel));

        // --- grantRole / revokeRole(bytes32, address) ---
        if (sel == ControllerSel.grantRole.selector || sel == ControllerSel.revokeRole.selector) {
            (bytes32 r, address a) = abi.decode(p, (bytes32, address));
            console.log("        role:             %s%s", vm.toString(r), _fmtKnownRole(r));
            console.log("        account:          %s", vm.toString(a));
            return;
        }

        // --- setMintRecipient(uint32, bytes32) ---
        if (sel == ControllerSel.setMintRecipient.selector) {
            (uint32 d, bytes32 r) = abi.decode(p, (uint32, bytes32));
            console.log("        domain:           %s", vm.toString(uint256(d)));
            console.log("        mintRecipient:    %s", vm.toString(r));
            return;
        }

        // --- setLayerZeroRecipient(uint32, bytes32) ---
        if (sel == ControllerSel.setLayerZeroRecipient.selector) {
            (uint32 e, bytes32 r) = abi.decode(p, (uint32, bytes32));
            console.log("        endpointId:       %s", vm.toString(uint256(e)));
            console.log("        recipient:        %s", vm.toString(r));
            return;
        }

        // --- setMaxSlippage(address, uint256) ---
        if (sel == ControllerSel.setMaxSlippage.selector) {
            (address a, uint256 v) = abi.decode(p, (address, uint256));
            console.log("        pool:             %s", vm.toString(a));
            console.log("        maxSlippage:      %s%s", vm.toString(v), _fmtWadPct(v));
            return;
        }

        // --- setMaxExchangeRate(address, uint256, uint256) ---
        if (sel == ControllerSel.setMaxExchangeRate.selector) {
            (address t, uint256 s, uint256 m) = abi.decode(p, (address, uint256, uint256));
            console.log("        token:            %s", vm.toString(t));
            console.log("        shares:           %s", vm.toString(s));
            console.log("        maxExpectedAssets: %s", vm.toString(m));
            return;
        }

        // --- setOTCBuffer(address, address) ---
        if (sel == ControllerSel.setOTCBuffer.selector) {
            (address a, address b) = abi.decode(p, (address, address));
            console.log("        exchange:         %s", vm.toString(a));
            console.log("        otcBuffer:        %s", vm.toString(b));
            return;
        }

        // --- setOTCRechargeRate(address, uint256) ---
        if (sel == ControllerSel.setOTCRechargeRate.selector) {
            (address a, uint256 v) = abi.decode(p, (address, uint256));
            console.log("        exchange:         %s", vm.toString(a));
            console.log("        rechargeRate:     %s", vm.toString(v));
            return;
        }

        // --- setOTCWhitelistedAsset(address, address, bool) ---
        if (sel == ControllerSel.setOTCWhitelistedAsset.selector) {
            (address a, address b, bool w) = abi.decode(p, (address, address, bool));
            console.log("        exchange:         %s", vm.toString(a));
            console.log("        asset:            %s", vm.toString(b));
            console.log("        whitelisted:      %s", w ? "true" : "false");
            return;
        }

        // --- setUniswapV4TickLimits(bytes32, int24, int24, uint24) ---
        if (sel == ControllerSel.setUniswapV4TickLimits.selector) {
            (bytes32 pid, int24 lo, int24 hi, uint24 sp) = abi.decode(p, (bytes32, int24, int24, uint24));
            console.log("        poolId:           %s", vm.toString(pid));
            console.log("        tickLowerMin:     %s", vm.toString(int256(lo)));
            console.log("        tickUpperMax:     %s", vm.toString(int256(hi)));
            console.log("        maxTickSpacing:   %s", vm.toString(uint256(sp)));
            return;
        }

        // --- setUniswapV3PoolMaxTickDelta(address, uint24) ---
        if (sel == ControllerSel.setUniswapV3PoolMaxTickDelta.selector) {
            (address a, uint24 d) = abi.decode(p, (address, uint24));
            console.log("        pool:             %s", vm.toString(a));
            console.log("        maxTickDelta:     %s", vm.toString(uint256(d)));
            return;
        }

        // --- setUniswapV3AddLiquidityLowerTickBound(address, int24) ---
        if (sel == ControllerSel.setUniswapV3AddLiquidityLowerTickBound.selector) {
            (address a, int24 b) = abi.decode(p, (address, int24));
            console.log("        pool:             %s", vm.toString(a));
            console.log("        lowerTickBound:   %s", vm.toString(int256(b)));
            return;
        }

        // --- setUniswapV3AddLiquidityUpperTickBound(address, int24) ---
        if (sel == ControllerSel.setUniswapV3AddLiquidityUpperTickBound.selector) {
            (address a, int24 b) = abi.decode(p, (address, int24));
            console.log("        pool:             %s", vm.toString(a));
            console.log("        upperTickBound:   %s", vm.toString(int256(b)));
            return;
        }

        // --- setUniswapV3TwapSecondsAgo(address, uint32) ---
        if (sel == ControllerSel.setUniswapV3TwapSecondsAgo.selector) {
            (address a, uint32 s) = abi.decode(p, (address, uint32));
            console.log("        pool:             %s", vm.toString(a));
            console.log("        twapSecondsAgo:   %s", vm.toString(uint256(s)));
            return;
        }

        // --- setCentrifugeRecipient(uint16, bytes32) ---
        if (sel == ControllerSel.setCentrifugeRecipient.selector) {
            (uint16 id_, bytes32 r) = abi.decode(p, (uint16, bytes32));
            console.log("        centrifugeId:     %s", vm.toString(uint256(id_)));
            console.log("        recipient:        %s", vm.toString(r));
            return;
        }

        // --- setMerklDistributor(address) ---
        if (sel == ControllerSel.setMerklDistributor.selector) {
            console.log("        distributor:      %s", vm.toString(abi.decode(p, (address))));
            return;
        }
    }

    // -------------------------------------------------------------------------
    // Formatting helpers
    // -------------------------------------------------------------------------

    function _fmtEta(uint256 eta) internal view returns (string memory) {
        if (eta == 0) return "n/a";
        if (eta == 1) return "done";
        string memory ts = vm.toString(eta);
        if (block.timestamp >= eta) return string.concat(ts, " (READY)");
        return string.concat(ts, " (in ", _fmtDuration(eta - block.timestamp), ")");
    }

    function _fmtDuration(uint256 s) internal pure returns (string memory) {
        if (s >= 1 days)  return string.concat(vm.toString(s / 1 days), "d ", vm.toString((s % 1 days) / 1 hours), "h");
        if (s >= 1 hours) return string.concat(vm.toString(s / 1 hours), "h ", vm.toString((s % 1 hours) / 1 minutes), "m");
        return string.concat(vm.toString(s / 1 minutes), "m");
    }

    function _fmtAmount(uint256 v) internal pure returns (string memory) {
        if (v == type(uint256).max) return "UNLIMITED (type(uint256).max)";
        return vm.toString(v);
    }

    function _fmtWadPct(uint256 v) internal pure returns (string memory) {
        if (v < 1e16) return "";
        uint256 pct = (v * 100) / 1e18;
        uint256 bps = ((v * 10000) / 1e18) % 100;
        if (bps > 0) {
            string memory bpsStr = bps < 10 ? string.concat("0", vm.toString(bps)) : vm.toString(bps);
            return string.concat(" (~", vm.toString(pct), ".", bpsStr, "%)");
        }
        return string.concat(" (~", vm.toString(pct), "%)");
    }

    function _fmtKnownRole(bytes32 r) internal pure returns (string memory) {
        if (r == keccak256("RELAYER"))         return " [RELAYER]";
        if (r == keccak256("FREEZER"))         return " [FREEZER]";
        if (r == bytes32(0))                   return " [DEFAULT_ADMIN]";
        if (r == keccak256("CANCELLER_ROLE"))  return " [CANCELLER]";
        if (r == keccak256("PROPOSER_ROLE"))   return " [PROPOSER]";
        if (r == keccak256("EXECUTOR_ROLE"))   return " [EXECUTOR]";
        if (r == keccak256("PAUSER_ROLE"))     return " [PAUSER]";
        return "";
    }

    // -------------------------------------------------------------------------
    // Selector -> Name mappings
    // -------------------------------------------------------------------------

    function _beamStateName(bytes4 sel) internal pure returns (string memory) {
        if (sel == BeamState.rely.selector)                     return "rely";
        if (sel == BeamState.deny.selector)                     return "deny";
        if (sel == BeamState.setUserRole.selector)              return "setUserRole";
        if (sel == BeamState.setRoleAction.selector)            return "setRoleAction";
        if (sel == BeamState.start.selector)                    return "start";
        if (sel == BeamState.stop.selector)                     return "stop";
        if (sel == BeamState.setHop.selector)                   return "setHop";
        if (sel == BeamState.setMaxChange.selector)             return "setMaxChange";
        if (sel == BeamState.addRateLimits.selector)            return "addRateLimits";
        if (sel == BeamState.delRateLimits.selector)            return "delRateLimits";
        if (sel == BeamState.addController.selector)            return "addController";
        if (sel == BeamState.delController.selector)            return "delController";
        if (sel == BeamState.addCBeam.selector)                 return "addCBeam";
        if (sel == BeamState.delCBeam.selector)                 return "delCBeam";
        if (sel == BeamState.setCBeamForRateLimits.selector)    return "setCBeamForRateLimits";
        if (sel == BeamState.unsetCBeamForRateLimits.selector)  return "unsetCBeamForRateLimits";
        if (sel == BeamState.setCBeamForController.selector)    return "setCBeamForController";
        if (sel == BeamState.unsetCBeamForController.selector)  return "unsetCBeamForController";
        if (sel == BeamState.addInitRateLimits.selector)        return "addInitRateLimits";
        if (sel == BeamState.delInitRateLimits.selector)        return "delInitRateLimits";
        if (sel == BeamState.addInitControllerActions.selector) return "addInitControllerActions";
        if (sel == BeamState.delInitControllerActions.selector) return "delInitControllerActions";
        return "unknown";
    }

    function _controllerName(bytes4 sel) internal pure returns (string memory) {
        if (sel == ControllerSel.grantRole.selector)                              return "grantRole";
        if (sel == ControllerSel.revokeRole.selector)                             return "revokeRole";
        if (sel == ControllerSel.setMintRecipient.selector)                       return "setMintRecipient";
        if (sel == ControllerSel.setLayerZeroRecipient.selector)                  return "setLayerZeroRecipient";
        if (sel == ControllerSel.setMaxSlippage.selector)                         return "setMaxSlippage";
        if (sel == ControllerSel.setMaxExchangeRate.selector)                     return "setMaxExchangeRate";
        if (sel == ControllerSel.setOTCBuffer.selector)                           return "setOTCBuffer";
        if (sel == ControllerSel.setOTCRechargeRate.selector)                     return "setOTCRechargeRate";
        if (sel == ControllerSel.setOTCWhitelistedAsset.selector)                 return "setOTCWhitelistedAsset";
        if (sel == ControllerSel.setUniswapV4TickLimits.selector)                 return "setUniswapV4TickLimits";
        if (sel == ControllerSel.setUniswapV3PoolMaxTickDelta.selector)           return "setUniswapV3PoolMaxTickDelta";
        if (sel == ControllerSel.setUniswapV3AddLiquidityLowerTickBound.selector) return "setUniswapV3AddLiquidityLowerTickBound";
        if (sel == ControllerSel.setUniswapV3AddLiquidityUpperTickBound.selector) return "setUniswapV3AddLiquidityUpperTickBound";
        if (sel == ControllerSel.setUniswapV3TwapSecondsAgo.selector)             return "setUniswapV3TwapSecondsAgo";
        if (sel == ControllerSel.setCentrifugeRecipient.selector)                 return "setCentrifugeRecipient";
        if (sel == ControllerSel.setMerklDistributor.selector)                    return "setMerklDistributor";
        return "unknown";
    }

    // -------------------------------------------------------------------------
    // Byte helpers
    // -------------------------------------------------------------------------

    function _stripSelector(bytes memory data) internal pure returns (bytes memory result) {
        uint256 len = data.length - 4;
        result = new bytes(len);
        for (uint256 i; i < len; ++i) {
            result[i] = data[i + 4];
        }
    }
}
