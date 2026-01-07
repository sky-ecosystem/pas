// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

interface BeamState {
    function setHop(address, uint256) external;
    function setMaxChange(address, uint256) external;
    function addCBeam(address) external;
    function delCBeam(address) external;
    function addCBeamForPau(address, address) external;
    function delCBeamForPau(address, address) external;
    function addInitRateLimits(bytes32, address, uint256, uint256) external;
    function addInitControllerActions(bytes calldata, address) external returns (bytes32);
    function delInitRateLimits(bytes32, address) external;
    function addInitControllerActions(bytes32, address) external;
    function delInitControllerActions(bytes32, address) external;
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

    function setHop(address pau, uint256 value) external onlySigner {
        beamState.setHop(pau, value);
    }

    function setMaxChange(address pau, uint256 value) external onlySigner {
        beamState.setHop(pau, value);
    }

    function addCBeam(address cBeam) external onlySigner {
        beamState.addCBeam(cBeam);
    }

    function addInitRateLimits(bytes32 key, address pau, uint256 maxAmount, uint256 slope) external onlySigner {
        beamState.addInitRateLimits(key, pau, maxAmount, slope);
    }

    function addInitControllerActions(bytes calldata data, address pau) external onlySigner returns (bytes32 key) {
        key = beamState.addInitControllerActions(data, pau);
    }

    function addInitControllerActions(bytes32 key, address pau) external onlySigner {
        beamState.addInitControllerActions(key, pau);
    }
}

contract BeamRoleDirect is BeamRole {
    constructor(address signer_, address beamState) BeamRole(signer_, beamState) {
    }

    function delCBeam(address cBeam) external onlySigner {
        beamState.delCBeam(cBeam);
    }

    function addCBeamForPau(address pau, address cBeam) external onlySigner {
        beamState.addCBeamForPau(pau, cBeam);
    }

    function delCBeamToPau(address pau, address cBeam) external onlySigner {
        beamState.delCBeamForPau(pau, cBeam);
    }

    function delInitRateLimits(bytes32 key, address pau) external onlySigner {
        beamState.delInitRateLimits(key, pau);
    }

    function delInitControllerActions(bytes32 key, address pau) external onlySigner {
        beamState.delInitControllerActions(key, pau);
    }
}
