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

// PAU code aligned to: https://github.com/sunbreak1211/pau/blob/a3e4b519c238d32c08c82145f04341144361e943/src/Option_4/Configurator.sol
// Spark Mainnet controller aligned to: https://github.com/sparkdotfi/spark-alm-controller/blob/3dbc7cb01739e91dad61a75cda8d7c84b4474e0b/src/MainnetController.sol
// Grove Mainnet controller aligned to: https://github.com/grove-labs/grove-alm-controller/blob/548c96fa22bcb13afd25cb592ec8cb4bb98c2d86/src/MainnetController.sol

// TODO: Consider renaming parameters for clarity - `rateLimits_` for rate limit functions, `controller` for controller functions

import { Timelock } from "src/timelock/Timelock.sol";

interface BeamStateLike {
    // Rate limit functions (timelocked)
    function setHop(address rateLimits_, uint256 value) external;
    function setMaxChange(address rateLimits_, uint256 value) external;
    function addRateLimits(address rateLimits_) external;
    function addInitRateLimits(bytes32 key, address rateLimits_, uint256 maxAmount, uint256 slope) external;
    
    // Controller functions (timelocked)
    function addController(address rateLimits_) external;
    function addInitControllerActions(bytes calldata data, address controller) external returns (bytes32 key);
    
    // CBeam functions (timelocked)
    function addCBeam(address cBeam) external;
    
    // System functions (timelocked)
    function start() external;
}

interface MainnetControllerLike {
    // Spark functions
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function setMintRecipient(uint32 destinationDomain, bytes32 mintRecipient) external;
    function setLayerZeroRecipient(uint32 destinationEndpointId, bytes32 layerZeroRecipient) external;
    function setMaxSlippage(address pool, uint256 maxSlippage) external;
    function setOTCBuffer(address exchange, address otcBuffer) external;
    function setOTCRechargeRate(address exchange, uint256 rechargeRate18) external;
    function setOTCWhitelistedAsset(address exchange, address asset, bool isWhitelisted) external;
    function setUniswapV4TickLimits(bytes32 poolId, int24 tickLowerMin, int24 tickUpperMax, uint24 maxTickSpacing) external;
    function setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external;
    // Grove-only functions
    function setCentrifugeRecipient(uint16 centrifugeId, bytes32 recipient) external;
    function setUniswapV3PoolLowerTick(address pool, int24 lowerTick) external;
    function setUniswapV3PoolUpperTick(address pool, int24 upperTick) external;
    function setUniswapV3PoolMaxTickDelta(address pool, uint24 maxTickDelta) external;
    function setUniswapV3PoolTwapSecondsAgo(address pool, uint32 twapSecondsAgo) external;
}

struct RateLimitConfig {
    bytes32 key;
    address rateLimits_;
    uint256 maxAmount;
    uint256 slope;
}

contract TimelockWrapper {
    // --- Auth ---
    mapping(address => uint256) public wards;
    mapping(address => uint256) public buds;

    modifier auth() {
        require(wards[msg.sender] == 1, "TimelockWrapper/not-authorized");
        _;
    }

    modifier toll() {
        require(buds[msg.sender] == 1, "TimelockWrapper/not-whitelisted");
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
    
    Timelock   public immutable timelock;
    BeamStateLike public immutable beamState;
    address       public immutable mainnetController; // TODO: unused for now
    
    constructor(address timelock_, address beamState_, address mainnetController_) {
        timelock          = Timelock(payable(timelock_));
        beamState         = BeamStateLike(beamState_);
        mainnetController = mainnetController_;
        
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }
    
    function _submitProposal(bytes memory payload, bytes32 predecessor, bytes32 salt, uint256 delay) internal returns (bytes32 operationId) {
        address[] memory targets = new address[](1);
        targets[0] = address(beamState);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;

        operationId = timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
    }

    // --- System Functions ---

    function start(bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.start.selector);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "start");
    }

    // --- Configuration Parameters ---

    function setHop(address rateLimits_, uint256 value, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(
            BeamStateLike.setHop.selector,
            rateLimits_,
            value
        );

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setHop");
    }

    function setMaxChange(address rateLimits_, uint256 value, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(
            BeamStateLike.setMaxChange.selector,
            rateLimits_,
            value
        );

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMaxChange");
    }

    // --- CBeam Management ---

    function addCBeam(address cBeam, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(
            BeamStateLike.addCBeam.selector,
            cBeam
        );

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "addCBeam");
    }

    // --- Rate Limits Management ---

    function addRateLimits(address rateLimits_, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addRateLimits.selector, rateLimits_);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "addRateLimits");
    }

    // --- Controller Management ---

    function addController(address rateLimits_, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addController.selector, rateLimits_);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "addController");
    }

    // --- Rate Limits ---

    function addInitRateLimits(
        RateLimitConfig calldata config,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(
            BeamStateLike.addInitRateLimits.selector,
            config.key,
            config.rateLimits_,
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
        require(len > 0, "TimelockWrapper/empty-configs");

        address[] memory targets = new address[](len);
        uint256[] memory values = new uint256[](len);
        bytes[] memory payloads = new bytes[](len);
        address target = address(beamState);

        for (uint256 i = 0; i < len; ++i) {
            targets[i] = target;
            payloads[i] = abi.encodeWithSelector(
                BeamStateLike.addInitRateLimits.selector,
                configs[i].key,
                configs[i].rateLimits_,
                configs[i].maxAmount,
                configs[i].slope
            );
        }

        operationId = timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);

        emit ProposalSubmitted(operationId, "batchAddInitRateLimits");
    }

    // --- Controller Actions ---

    // Spark functions

    // Common roles: RELAYER = keccak256("RELAYER"), FREEZER = keccak256("FREEZER")
    // Role bytes32 can be computed off-chain and passed as parameter
    function grantRole(
        address controller,
        bytes32 role,
        address account,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.grantRole.selector,
            role,
            account
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "grantRole");
    }

    function revokeRole(
        address controller,
        bytes32 role,
        address account,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.revokeRole.selector,
            role,
            account
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "revokeRole");
    }

    function setMintRecipient(
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setMintRecipient.selector,
            destinationDomain,
            mintRecipient
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMintRecipient");
    }
    
    function setLayerZeroRecipient(
        uint32 destinationEndpointId,
        bytes32 layerZeroRecipient,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setLayerZeroRecipient.selector,
            destinationEndpointId,
            layerZeroRecipient
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setLayerZeroRecipient");
    }
    
    function setMaxSlippage(
        address pool,
        uint256 maxSlippage,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setMaxSlippage.selector,
            pool,
            maxSlippage
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMaxSlippage");
    }
    
    function setOTCBuffer(
        address exchange,
        address otcBuffer,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setOTCBuffer.selector,
            exchange,
            otcBuffer
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setOTCBuffer");
    }
    
    function setOTCRechargeRate(
        address exchange,
        uint256 rechargeRate18,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setOTCRechargeRate.selector,
            exchange,
            rechargeRate18
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setOTCRechargeRate");
    }
    
    function setOTCWhitelistedAsset(
        address exchange,
        address asset,
        bool isWhitelisted,
        address controller,
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
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setOTCWhitelistedAsset");
    }
    
    function setUniswapV4TickLimits(
        bytes32 poolId,
        int24 tickLowerMin,
        int24 tickUpperMax,
        uint24 maxTickSpacing,
        address controller,
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
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV4TickLimits");
    }
    
    function setMaxExchangeRate(
        address token,
        uint256 shares,
        uint256 maxExpectedAssets,
        address controller,
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
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMaxExchangeRate");
    }
    
    // Grove-only functions
    
    function setCentrifugeRecipient(
        uint16 centrifugeId,
        bytes32 recipient,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setCentrifugeRecipient.selector,
            centrifugeId,
            recipient
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setCentrifugeRecipient");
    }
    
    function setUniswapV3PoolLowerTick(
        address pool,
        int24 lowerTick,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setUniswapV3PoolLowerTick.selector,
            pool,
            lowerTick
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV3PoolLowerTick");
    }
    
    function setUniswapV3PoolUpperTick(
        address pool,
        int24 upperTick,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setUniswapV3PoolUpperTick.selector,
            pool,
            upperTick
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV3PoolUpperTick");
    }
    
    function setUniswapV3PoolMaxTickDelta(
        address pool,
        uint24 maxTickDelta,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setUniswapV3PoolMaxTickDelta.selector,
            pool,
            maxTickDelta
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV3PoolMaxTickDelta");
    }
    
    function setUniswapV3PoolTwapSecondsAgo(
        address pool,
        uint32 twapSecondsAgo,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            MainnetControllerLike.setUniswapV3PoolTwapSecondsAgo.selector,
            pool,
            twapSecondsAgo
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV3PoolTwapSecondsAgo");
    }
}

