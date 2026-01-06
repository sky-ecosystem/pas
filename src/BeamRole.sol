// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

interface BeamState {
    function addCBeam(address cBeam) external;
    function delCBeam(address cBeam) external;
    function addCBeamForRBeam(address rBeam, address cBeam) external;
    function delCBeamForRBeam(address rBeam, address cBeam) external;
    function addInitRateLimits(bytes32 key, address rBeam, uint256 maxAmount, uint256 slope) external;
    function addInitControllerActions(bytes calldata data, address rBeam) external returns (bytes32 key);
    function delInitRateLimits(bytes32 key, address rBeam) external;
    function addInitControllerActions(bytes32 key, address rBeam) external;
    function delInitControllerActions(bytes32 key, address rBeam) external;
}

abstract contract BeamRole {
    address immutable public signer;
    BeamState immutable public beamState;

    modifier onlySigner() {
        require(msg.sender == signer, "BeamRole/not-signer");
        _;
    }

    constructor(address signer_, address beamState_) {
        signer = signer_;
        beamState = BeamState(beamState_);
    }
}

contract BeamRoleTimeLock is BeamRole {
    constructor(address signer_, address beamState_) BeamRole(signer_, beamState_) {
    }

    function addCBeam(address cBeam) external onlySigner {
        beamState.addCBeam(cBeam);
    }

    function addInitRateLimits(bytes32 key, address rBeam, uint256 maxAmount, uint256 slope) external onlySigner {
        beamState.addInitRateLimits(key, rBeam, maxAmount, slope);
    }

    function addInitControllerActions(bytes calldata data, address rBeam) external onlySigner returns (bytes32 key) {
        key = beamState.addInitControllerActions(data, rBeam);
    }

    function addInitControllerActions(bytes32 key, address rBeam) external onlySigner {
        beamState.addInitControllerActions(key, rBeam);
    }
}

contract BeamRoleDirect is BeamRole {
    constructor(address signer_, address beamState) BeamRole(signer_, beamState) {
    }

    function delCBeam(address cBeam) external onlySigner {
        beamState.delCBeam(cBeam);
    }

    function addCBeamForRBeam(address rBeam, address cBeam) external onlySigner {
        beamState.addCBeamForRBeam(rBeam, cBeam);
    }

    function delCBeamToRBeam(address rBeam, address cBeam) external onlySigner {
        beamState.delCBeamForRBeam(rBeam, cBeam);
    }

    function delInitRateLimits(bytes32 key, address rBeam) external onlySigner {
        beamState.delInitRateLimits(key, rBeam);
    }

    function delInitControllerActions(bytes32 key, address rBeam) external onlySigner {
        beamState.delInitControllerActions(key, rBeam);
    }
}
