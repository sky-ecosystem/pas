// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

interface AtwlState {
    function addGovOps(address pau, address usr) external;
    function delGovOps(address pau, address usr) external;
    function addInitRateLimits(bytes32 key, address pau, uint256 maxAmount, uint256 slope) external;
    function addInitControllerActions(bytes calldata data, address pau) external returns (bytes32 key);
    function delInitRateLimits(bytes32 key, address pau) external;
    function addInitControllerActions(bytes32 key, address pau) external;
    function delInitControllerActions(bytes32 key, address pau) external;
}

abstract contract ATWLRole {
    address immutable public signer;
    AtwlState immutable public atwlState;

    modifier onlySigner() {
        require(msg.sender == signer, "ATWLRole/not-signer");
        _;
    }

    constructor(address signer_, address atwlState_) {
        signer = signer_;
        atwlState = AtwlState(atwlState_);
    }
}

contract ATWLRoleTimeLock is ATWLRole {
    constructor(address signer_, address atwlState_) ATWLRole(signer_, atwlState_) {
    }

    function addGovOps(address pau, address usr) external onlySigner {
        atwlState.addGovOps(pau, usr);
    }

    function addInitRateLimits(bytes32 key, address pau, uint256 maxAmount, uint256 slope) external onlySigner {
        atwlState.addInitRateLimits(key, pau, maxAmount, slope);
    }

    function addInitControllerActions(bytes calldata data, address pau) external onlySigner returns (bytes32 key) {
        key = atwlState.addInitControllerActions(data, pau);
    }

    function addInitControllerActions(bytes32 key, address pau) external onlySigner {
        atwlState.addInitControllerActions(key, pau);
    }
}

contract ATWLRoleDirect is ATWLRole {
    constructor(address signer_, address atwlState) ATWLRole(signer_, atwlState) {
    }

    function delGovOps(address pau, address usr) external onlySigner {
        atwlState.delGovOps(pau, usr);
    }

    function delInitRateLimits(bytes32 key, address pau) external onlySigner {
        atwlState.delInitRateLimits(key, pau);
    }

    function delInitControllerActions(bytes32 key, address pau) external onlySigner {
        atwlState.delInitControllerActions(key, pau);
    }
}
