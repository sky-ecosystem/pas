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

interface TimelockLike {
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external view returns (bytes32);
}

interface BeamStateLike {
    function start() external;
    function setHop(address rateLimits_, uint256 value) external;
    function setMaxChange(address rateLimits_, uint256 value) external;
    function addRateLimits(address rateLimits_) external;
    function addController(address controller) external;
    function addCBeam(address cBeam) external;
    function addInitRateLimits(bytes32 key, address rateLimits_, uint256 maxAmount, uint256 slope) external;
    function addInitControllerActions(bytes calldata data, address controller) external returns (bytes32 key);
}

interface ControllerLike {
    // Shared functions (Spark v1.8.0 & Grove v1.8.0)
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function setMintRecipient(uint32 destinationDomain, bytes32 mintRecipient) external;
    function setLayerZeroRecipient(uint32 destinationEndpointId, bytes32 layerZeroRecipient) external;
    function setMaxSlippage(address pool, uint256 maxSlippage) external;
    function setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external;
    // Grove-only functions (v1.8.0)
    function setUniswapV3PoolMaxTickDelta(address pool, uint24 maxTickDelta) external;
    function setUniswapV3AddLiquidityLowerTickBound(address pool, int24 lowerTickBound) external;
    function setUniswapV3AddLiquidityUpperTickBound(address pool, int24 upperTickBound) external;
    function setUniswapV3TwapSecondsAgo(address pool, uint32 twapSecondsAgo) external;
    function setCentrifugeRecipient(uint16 centrifugeId, bytes32 recipient) external;
    function setMerklDistributor(address merklDistributor) external;
}

struct RateLimitConfig {
    bytes32 key;
    address rateLimits;
    uint256 maxAmount;
    uint256 slope;
}

// Spark Foreign controller aligned to v1.8.0: https://github.com/sparkdotfi/spark-alm-controller/blob/7be959378fe48117f7a06796f94e240345428982/src/ForeignController.sol
// Grove Foreign controller aligned to v1.8.0: https://github.com/grove-labs/grove-alm-controller/blob/2c6e3d4297d5f244894d05f3dbbe47bcada34712/src/ForeignController.sol

// Notes:
// - This wrapper is assumed as a helper only, and can be bypassed by submitting payloads directly to the Timelock (for an authorised proposer).
// - The wrapper is assumed to be frequently replaced/improved, depending on downstream contracts changes or other needs.
// - The actual downstream changes only take effect when cBEAMs use the BeamState configurations, so atomicity in configurations can not be assumed (which is a known issue).
// - As part of a controller onboarding it might need to be `kiss`ed on the PSM. That is assumed to be orchestrated without the wrapper.
contract TimelockWrapperForeign {
    // --- Auth ---
    mapping(address => uint256) public wards;
    mapping(address => uint256) public buds;

    modifier auth() {
        require(wards[msg.sender] == 1, "TimelockWrapperForeign/not-authorized");
        _;
    }

    modifier toll() {
        require(buds[msg.sender] == 1, "TimelockWrapperForeign/not-whitelisted");
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

    TimelockLike  public immutable timelock;
    BeamStateLike public immutable beamState;

    constructor(address timelock_, address beamState_) {
        timelock  = TimelockLike(payable(timelock_));
        beamState = BeamStateLike(beamState_);

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

    function start(bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.start.selector);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "start");
    }

    function setHop(address rateLimits, uint256 hop, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.setHop.selector, rateLimits, hop);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setHop");
    }

    function setMaxChange(address rateLimits, uint256 maxChange, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.setMaxChange.selector, rateLimits, maxChange);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMaxChange");
    }

    function addRateLimits(address rateLimits, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addRateLimits.selector, rateLimits);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "addRateLimits");
    }

    function addController(address controller, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addController.selector, controller);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "addController");
    }

    function addCBeam(address cBeam, bytes32 predecessor, bytes32 salt, uint256 delay) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addCBeam.selector, cBeam);
        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "addCBeam");
    }

    function addInitRateLimits(
        RateLimitConfig calldata config,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory payload = abi.encodeWithSelector(
            BeamStateLike.addInitRateLimits.selector,
            config.key,
            config.rateLimits,
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

        address[] memory targets = new address[](len);
        uint256[] memory values = new uint256[](len);
        bytes[] memory payloads = new bytes[](len);

        for (uint256 i = 0; i < len; ++i) {
            targets[i] = address(beamState);
            payloads[i] = abi.encodeWithSelector(
                BeamStateLike.addInitRateLimits.selector,
                configs[i].key,
                configs[i].rateLimits,
                configs[i].maxAmount,
                configs[i].slope
            );
        }

        operationId = timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
        timelock.scheduleBatch(targets, values, payloads, predecessor, salt, delay);

        emit ProposalSubmitted(operationId, "batchAddInitRateLimits");
    }

    // --- Controller Actions ---

    // Shared Spark & Grove functions

    // Role bytes32 can be computed off-chain and passed as parameter, e.g keccak256("RELAYER"), keccak256("FREEZER")
    function grantRole(
        address controller,
        bytes32 role,
        address account,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            ControllerLike.grantRole.selector,
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
            ControllerLike.revokeRole.selector,
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
            ControllerLike.setMintRecipient.selector,
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
            ControllerLike.setLayerZeroRecipient.selector,
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
            ControllerLike.setMaxSlippage.selector,
            pool,
            maxSlippage
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMaxSlippage");
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
            ControllerLike.setMaxExchangeRate.selector,
            token,
            shares,
            maxExpectedAssets
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMaxExchangeRate");
    }

    // Grove-only functions

    function setUniswapV3PoolMaxTickDelta(
        address pool,
        uint24 maxTickDelta,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            ControllerLike.setUniswapV3PoolMaxTickDelta.selector,
            pool,
            maxTickDelta
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV3PoolMaxTickDelta");
    }

    function setUniswapV3AddLiquidityLowerTickBound(
        address pool,
        int24 lowerTickBound,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            ControllerLike.setUniswapV3AddLiquidityLowerTickBound.selector,
            pool,
            lowerTickBound
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV3AddLiquidityLowerTickBound");
    }

    function setUniswapV3AddLiquidityUpperTickBound(
        address pool,
        int24 upperTickBound,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            ControllerLike.setUniswapV3AddLiquidityUpperTickBound.selector,
            pool,
            upperTickBound
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV3AddLiquidityUpperTickBound");
    }

    function setUniswapV3TwapSecondsAgo(
        address pool,
        uint32 twapSecondsAgo,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            ControllerLike.setUniswapV3TwapSecondsAgo.selector,
            pool,
            twapSecondsAgo
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setUniswapV3TwapSecondsAgo");
    }

    function setCentrifugeRecipient(
        uint16 centrifugeId,
        bytes32 recipient,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            ControllerLike.setCentrifugeRecipient.selector,
            centrifugeId,
            recipient
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setCentrifugeRecipient");
    }

    function setMerklDistributor(
        address merklDistributor,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external toll returns (bytes32 operationId) {
        bytes memory controllerData = abi.encodeWithSelector(
            ControllerLike.setMerklDistributor.selector,
            merklDistributor
        );
        bytes memory payload = abi.encodeWithSelector(BeamStateLike.addInitControllerActions.selector, controllerData, controller);

        operationId = _submitProposal(payload, predecessor, salt, delay);
        emit ProposalSubmitted(operationId, "setMerklDistributor");
    }
}
