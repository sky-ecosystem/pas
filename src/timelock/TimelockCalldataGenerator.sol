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

// --- Facet interfaces ---
// Diamond-PAU facet admin-role functions (https://github.com/sky-ecosystem/diamond-pau/tree/dev/src/facets).
// One interface per facet contract — multiple facets share the same selector for some functions
// (e.g. `setMaxSlippage(address,uint256)`), so keeping them in distinct interfaces preserves the
// per-facet parameter names and clarifies which facet a generator function targets.

interface IAaveFacet {
    function setMaxSlippage(address aToken, uint256 maxSlippage) external;
}

interface ICCTPFacet {
    function setDomainParameters(
        uint32  destinationDomain,
        bytes32 recipient,
        uint32  minFeeCapRate,
        uint32  maxFeeCapRate
    ) external;
}

interface ICentrifugeFacet {
    function setRecipient(uint16 centrifugeId, bytes32 recipient) external;
}

interface ICurveFacet {
    function setMaxSlippage(address pool, uint256 maxSlippage) external;
}

interface IERC4626Facet {
    function setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external;
}

interface ILayerZeroFacet {
    function setRecipient(uint32 destinationEndpointId, bytes32 recipient) external;
}

interface IOTCBuffer {
    function approve(address asset, uint256 allowance) external;
}

interface IOTCFacet {
    function setMaxSlippage(address exchange, uint256 maxSlippage) external;
    function setBuffer(address exchange, address buffer) external;
    function setRechargeRate(address exchange, uint256 normalizedRate) external;
}

interface IUniswapV3Facet {
    function setMaxSlippage(address pool, uint256 maxSlippage) external;
    function setMaxTickDelta(address pool, uint24 maxTickDelta) external;
    function setLiquidityLowerTickBound(address pool, int24 lowerTickBound) external;
    function setLiquidityUpperTickBound(address pool, int24 upperTickBound) external;
    function setTWAPSecondsAgo(address pool, uint32 twapSecondsAgo) external;
}

interface IUniswapV4Facet {
    function setMaxSlippage(bytes32 poolId, uint256 maxSlippage) external;
    function setTickLimits(
        bytes32 poolId,
        int24   tickLowerMin,
        int24   tickUpperMax,
        uint24  maxTickSpacing
    ) external;
}

interface IUSDSFacet {
    function setVault(address vault_) external;
}

struct RateLimitConfig {
    bytes32 key;
    address rateLimits;
    uint256 maxAmount;
    uint256 slope;
}

// Notes:
// - This generator is a helper only and can be bypassed by submitting payloads directly to the Timelock (for an authorised proposer).
// - The generator is assumed to be frequently replaced/improved, depending on downstream facet changes or other needs.
// - The actual downstream changes only take effect when cBEAMs use the BeamState configurations, so atomicity in configurations can not be assumed (which is a known issue).
// - As part of a controller onboarding it might need to be `kiss`ed on the PSM. That is assumed to be orchestrated without the generator.
contract TimelockCalldataGenerator {

    TimelockLike  public immutable timelock;
    BeamStateLike public immutable beamState;

    constructor(address timelock_, address beamState_) {
        timelock  = TimelockLike(payable(timelock_));
        beamState = BeamStateLike(beamState_);
    }

    function _encodeProposal(bytes memory payload, bytes32 predecessor, bytes32 salt, uint256 delay) internal view returns (bytes memory data) {
        address[] memory targets = new address[](1);
        targets[0] = address(beamState);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;

        data = abi.encodeCall(timelock.scheduleBatch, (targets, values, payloads, predecessor, salt, delay));
    }

    function _encodeControllerAction(bytes memory controllerData, address controller, bytes32 predecessor, bytes32 salt, uint256 delay) internal view returns (bytes memory data) {
        bytes memory payload = abi.encodeCall(BeamStateLike.addInitControllerActions, (controllerData, controller));
        data = _encodeProposal(payload, predecessor, salt, delay);
    }

    // --- BeamState Configuration ---

    function start(bytes32 predecessor, bytes32 salt, uint256 delay) external view returns (bytes memory data) {
        bytes memory payload = abi.encodeCall(BeamStateLike.start, ());
        data = _encodeProposal(payload, predecessor, salt, delay);
    }

    function setHop(address rateLimits, uint256 hop, bytes32 predecessor, bytes32 salt, uint256 delay) external view returns (bytes memory data) {
        bytes memory payload = abi.encodeCall(BeamStateLike.setHop, (rateLimits, hop));
        data = _encodeProposal(payload, predecessor, salt, delay);
    }

    function setMaxChange(address rateLimits, uint256 maxChange, bytes32 predecessor, bytes32 salt, uint256 delay) external view returns (bytes memory data) {
        bytes memory payload = abi.encodeCall(BeamStateLike.setMaxChange, (rateLimits, maxChange));
        data = _encodeProposal(payload, predecessor, salt, delay);
    }

    function addRateLimits(address rateLimits, bytes32 predecessor, bytes32 salt, uint256 delay) external view returns (bytes memory data) {
        bytes memory payload = abi.encodeCall(BeamStateLike.addRateLimits, (rateLimits));
        data = _encodeProposal(payload, predecessor, salt, delay);
    }

    function addController(address controller, bytes32 predecessor, bytes32 salt, uint256 delay) external view returns (bytes memory data) {
        bytes memory payload = abi.encodeCall(BeamStateLike.addController, (controller));
        data = _encodeProposal(payload, predecessor, salt, delay);
    }

    function addCBeam(address cBeam, bytes32 predecessor, bytes32 salt, uint256 delay) external view returns (bytes memory data) {
        bytes memory payload = abi.encodeCall(BeamStateLike.addCBeam, (cBeam));
        data = _encodeProposal(payload, predecessor, salt, delay);
    }

    function addInitRateLimits(
        RateLimitConfig calldata config,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory payload = abi.encodeCall(
            BeamStateLike.addInitRateLimits,
            (config.key, config.rateLimits, config.maxAmount, config.slope)
        );

        data = _encodeProposal(payload, predecessor, salt, delay);
    }

    function batchAddInitRateLimits(
        RateLimitConfig[] calldata configs,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        uint256 len = configs.length;

        address[] memory targets = new address[](len);
        uint256[] memory values = new uint256[](len);
        bytes[] memory payloads = new bytes[](len);

        for (uint256 i = 0; i < len; ++i) {
            targets[i] = address(beamState);
            payloads[i] = abi.encodeCall(
                BeamStateLike.addInitRateLimits,
                (configs[i].key, configs[i].rateLimits, configs[i].maxAmount, configs[i].slope)
            );
        }

        data = abi.encodeCall(timelock.scheduleBatch, (targets, values, payloads, predecessor, salt, delay));
    }

    // --- Controller Actions (Diamond-PAU facets) ---
    // Naming convention: `<facet>_<function>(...)`. The `controller` parameter is the address that the
    // configurator will dispatch the call to (typically the diamond proxy, or the OTCBuffer proxy for
    // `otcBuffer_approve`).

    // AaveFacet

    function aave_setMaxSlippage(
        address aToken,
        uint256 maxSlippage,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IAaveFacet.setMaxSlippage, (aToken, maxSlippage));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // CCTPFacet

    function cctp_setDomainParameters(
        uint32 destinationDomain,
        bytes32 recipient,
        uint32 minFeeCapRate,
        uint32 maxFeeCapRate,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(
            ICCTPFacet.setDomainParameters,
            (destinationDomain, recipient, minFeeCapRate, maxFeeCapRate)
        );
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // CentrifugeFacet

    function centrifuge_setRecipient(
        uint16 centrifugeId,
        bytes32 recipient,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(ICentrifugeFacet.setRecipient, (centrifugeId, recipient));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // CurveFacet

    function curve_setMaxSlippage(
        address pool,
        uint256 maxSlippage,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(ICurveFacet.setMaxSlippage, (pool, maxSlippage));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // ERC4626Facet

    function erc4626_setMaxExchangeRate(
        address token,
        uint256 shares,
        uint256 maxExpectedAssets,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(
            IERC4626Facet.setMaxExchangeRate,
            (token, shares, maxExpectedAssets)
        );
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // LayerZeroFacet

    function layerZero_setRecipient(
        uint32 destinationEndpointId,
        bytes32 recipient,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(
            ILayerZeroFacet.setRecipient,
            (destinationEndpointId, recipient)
        );
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // OTCBuffer (separate UUPS-upgradeable contract under src/facets/otc/)

    function otcBuffer_approve(
        address asset,
        uint256 allowance,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IOTCBuffer.approve, (asset, allowance));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // OTCFacet

    function otc_setMaxSlippage(
        address exchange,
        uint256 maxSlippage,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IOTCFacet.setMaxSlippage, (exchange, maxSlippage));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    function otc_setBuffer(
        address exchange,
        address buffer,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IOTCFacet.setBuffer, (exchange, buffer));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    function otc_setRechargeRate(
        address exchange,
        uint256 normalizedRate,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IOTCFacet.setRechargeRate, (exchange, normalizedRate));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // UniswapV3Facet

    function uniswapV3_setMaxSlippage(
        address pool,
        uint256 maxSlippage,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IUniswapV3Facet.setMaxSlippage, (pool, maxSlippage));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    function uniswapV3_setMaxTickDelta(
        address pool,
        uint24 maxTickDelta,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IUniswapV3Facet.setMaxTickDelta, (pool, maxTickDelta));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    function uniswapV3_setLiquidityLowerTickBound(
        address pool,
        int24 lowerTickBound,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(
            IUniswapV3Facet.setLiquidityLowerTickBound,
            (pool, lowerTickBound)
        );
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    function uniswapV3_setLiquidityUpperTickBound(
        address pool,
        int24 upperTickBound,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(
            IUniswapV3Facet.setLiquidityUpperTickBound,
            (pool, upperTickBound)
        );
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    function uniswapV3_setTWAPSecondsAgo(
        address pool,
        uint32 twapSecondsAgo,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(
            IUniswapV3Facet.setTWAPSecondsAgo,
            (pool, twapSecondsAgo)
        );
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // UniswapV4Facet

    function uniswapV4_setMaxSlippage(
        bytes32 poolId,
        uint256 maxSlippage,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IUniswapV4Facet.setMaxSlippage, (poolId, maxSlippage));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    function uniswapV4_setTickLimits(
        bytes32 poolId,
        int24 tickLowerMin,
        int24 tickUpperMax,
        uint24 maxTickSpacing,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(
            IUniswapV4Facet.setTickLimits,
            (poolId, tickLowerMin, tickUpperMax, maxTickSpacing)
        );
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }

    // USDSFacet

    function usds_setVault(
        address vault,
        address controller,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external view returns (bytes memory data) {
        bytes memory controllerData = abi.encodeCall(IUSDSFacet.setVault, (vault));
        data = _encodeControllerAction(controllerData, controller, predecessor, salt, delay);
    }
}
