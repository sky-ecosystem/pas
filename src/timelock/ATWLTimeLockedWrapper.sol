// SPDX-FileCopyrightText: © 2025 Dai Foundation <www.daifoundation.org>
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

// Code aligned to: https://github.com/sunbreak1211/pau/blob/a3e4b519c238d32c08c82145f04341144361e943/src/Option_4/Configurator.sol
// TODO: Rename `pau` parameter to `almController` and `rateLimiter` - current name is ambiguous (depends on external contract changes)

import {SkyTimelock} from "src/timelock/SkyTimelock.sol";

interface ATWLRoleTimeLockLike {
    function addGovOps(address pau, address usr) external;
    function addInitRateLimits(bytes32 key, address pau, uint256 maxAmount, uint256 slope) external;
    function addInitControllerActions(bytes calldata data, address pau) external returns (bytes32 key);
    // Note: The overloaded function addInitControllerActions(bytes32 key, address pau) from ATWLRole.sol (lines 45-46) is not supported
}

interface MainnetControllerLike {
    function setMintRecipient(uint32 destinationDomain, bytes32 mintRecipient) external;
    function setLayerZeroRecipient(uint32 destinationEndpointId, bytes32 layerZeroRecipient) external;
    function setMaxSlippage(address pool, uint256 maxSlippage) external;
    function setOTCBuffer(address exchange, address otcBuffer) external;
    function setOTCRechargeRate(address exchange, uint256 rechargeRate18) external;
    function setOTCWhitelistedAsset(address exchange, address asset, bool isWhitelisted) external;
    function setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external;
    function setUniswapV4TickLimits(bytes32 poolId, int24 tickLowerMin, int24 tickUpperMax, uint24 maxTickSpacing) external;
}

struct RateLimitConfig {
    bytes32 key;
    address pau;
    uint256 maxAmount;
    uint256 slope;
}

contract ATWLTimeLockedWrapper {
    // --- Auth ---
    mapping(address => uint256) public wards;
    mapping(address => uint256) public buds;

    modifier auth() {
        require(wards[msg.sender] == 1, "ATWLTimeLockedWrapper/not-authorized");
        _;
    }

    modifier toll() {
        require(buds[msg.sender] == 1, "ATWLTimeLockedWrapper/not-whitelisted");
        _;
    }

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function kiss(address usr) external auth {
        buds[usr] = 1;
        emit Kiss(usr);
    }

    function diss(address usr) external auth {
        buds[usr] = 0;
        emit Diss(usr);
    }
    
    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);
    event ProposalSubmitted(bytes32 indexed operationId, string functionName);
    
    SkyTimelock          public immutable timelock;
    ATWLRoleTimeLockLike public immutable atwlRoleTimeLock; // TODO: consider changing to atwlState
    address              public immutable mainnetController; // TODO: unused for now
    
    constructor(address timelock_, address atwlRoleTimeLock_, address mainnetController_) {
        timelock          = SkyTimelock(payable(timelock_));
        atwlRoleTimeLock  = ATWLRoleTimeLockLike(atwlRoleTimeLock_);
        mainnetController = mainnetController_;
        
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }
    
    function _submitProposal(bytes memory payload, bytes32 predecessor, bytes32 salt, uint256 delay) internal returns (bytes32 operationId) {
        address[] memory targets = new address[](1);
        targets[0] = address(atwlRoleTimeLock);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;

        operationId = timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
    }

    // --- Governance Operations ---

    function addGovOps(address pau, address usr, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(
            ATWLRoleTimeLockLike.addGovOps.selector,
            pau,
            usr
        );

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "addGovOps");
    }

    // --- Rate Limits ---

    function addInitRateLimits(
        RateLimitConfig calldata config,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(
            ATWLRoleTimeLockLike.addInitRateLimits.selector,
            config.key,
            config.pau,
            config.maxAmount,
            config.slope
        );

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "addInitRateLimits");
    }

    function batchAddInitRateLimits(
        RateLimitConfig[] calldata configs,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        uint256 len = configs.length;
        require(len > 0, "ATWLTimeLockedWrapper/empty-configs");

        address[] memory targets = new address[](len);
        uint256[] memory values = new uint256[](len);
        bytes[] memory payloads = new bytes[](len);
        address target = address(atwlRoleTimeLock);

        for (uint256 i = 0; i < len; ++i) {
            targets[i] = target;
            payloads[i] = abi.encodeWithSelector(
                ATWLRoleTimeLockLike.addInitRateLimits.selector,
                configs[i].key,
                configs[i].pau,
                configs[i].maxAmount,
                configs[i].slope
            );
        }

        operationId = timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);

        emit ProposalSubmitted(operationId, "batchAddInitRateLimits");
    }

    // --- Controller Actions ---

    function setMintRecipient(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address pau,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setMintRecipient.selector,
            destinationDomain,
            mintRecipient
        );
        bytes memory payload = abi.encodeWithSelector(ATWLRoleTimeLockLike.addInitControllerActions.selector, controllerData, pau);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMintRecipient");
    }
    
    function setLayerZeroRecipient(
        uint32 destinationEndpointId,
        bytes32 layerZeroRecipient,
        address pau,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setLayerZeroRecipient.selector,
            destinationEndpointId,
            layerZeroRecipient
        );
        bytes memory payload = abi.encodeWithSelector(ATWLRoleTimeLockLike.addInitControllerActions.selector, controllerData, pau);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setLayerZeroRecipient");
    }
    
    function setMaxSlippage(
        address pool,
        uint256 maxSlippage,
        address pau,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setMaxSlippage.selector,
            pool,
            maxSlippage
        );
        bytes memory payload = abi.encodeWithSelector(ATWLRoleTimeLockLike.addInitControllerActions.selector, controllerData, pau);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMaxSlippage");
    }
    
    function setOTCBuffer(
        address exchange,
        address otcBuffer,
        address pau,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setOTCBuffer.selector,
            exchange,
            otcBuffer
        );
        bytes memory payload = abi.encodeWithSelector(ATWLRoleTimeLockLike.addInitControllerActions.selector, controllerData, pau);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setOTCBuffer");
    }
    
    function setOTCRechargeRate(
        address exchange,
        uint256 rechargeRate18,
        address pau,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setOTCRechargeRate.selector,
            exchange,
            rechargeRate18
        );
        bytes memory payload = abi.encodeWithSelector(ATWLRoleTimeLockLike.addInitControllerActions.selector, controllerData, pau);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setOTCRechargeRate");
    }
    
    function setOTCWhitelistedAsset(
        address exchange,
        address asset,
        bool isWhitelisted,
        address pau,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setOTCWhitelistedAsset.selector,
            exchange,
            asset,
            isWhitelisted
        );
        bytes memory payload = abi.encodeWithSelector(ATWLRoleTimeLockLike.addInitControllerActions.selector, controllerData, pau);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setOTCWhitelistedAsset");
    }
    
    function setUniswapV4TickLimits(
        bytes32 poolId,
        int24 tickLowerMin,
        int24 tickUpperMax,
        uint24 maxTickSpacing,
        address pau,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setUniswapV4TickLimits.selector,
            poolId,
            tickLowerMin,
            tickUpperMax,
            maxTickSpacing
        );
        bytes memory payload = abi.encodeWithSelector(ATWLRoleTimeLockLike.addInitControllerActions.selector, controllerData, pau);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV4TickLimits");
    }
    
    function setMaxExchangeRate(
        address token,
        uint256 shares,
        uint256 maxExpectedAssets,
        address pau,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setMaxExchangeRate.selector,
            token,
            shares,
            maxExpectedAssets
        );
        bytes memory payload = abi.encodeWithSelector(ATWLRoleTimeLockLike.addInitControllerActions.selector, controllerData, pau);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMaxExchangeRate");
    }
}

