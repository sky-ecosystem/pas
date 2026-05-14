// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.24;

// Minimal mock that exposes one Solidity function per UNIQUE admin-role selector across
// the diamond-pau facets. Multiple facets share the same selector (e.g.
// `setMaxSlippage(address,uint256)` exists on Aave, Curve, OTC and UniswapV3) — those
// hit the same function here, which is enough to verify the generator-built calldata
// dispatches correctly when executed via the Configurator.
contract MockFacetController {

    // setMaxSlippage(address,uint256) — Aave / Curve / OTC / UniswapV3
    mapping(address => uint256) public maxSlippageByAddress;

    function setMaxSlippage(address account, uint256 maxSlippage) external {
        maxSlippageByAddress[account] = maxSlippage;
    }

    // setMaxSlippage(bytes32,uint256) — UniswapV4
    mapping(bytes32 => uint256) public maxSlippageByPoolId;

    function setMaxSlippage(bytes32 poolId, uint256 maxSlippage) external {
        maxSlippageByPoolId[poolId] = maxSlippage;
    }

    // setRecipient(uint32,bytes32) — LayerZero
    mapping(uint32 => bytes32) public layerZeroRecipients;

    function setRecipient(uint32 destinationEndpointId, bytes32 recipient) external {
        layerZeroRecipients[destinationEndpointId] = recipient;
    }

    // setRecipient(uint16,bytes32) — Centrifuge
    mapping(uint16 => bytes32) public centrifugeRecipients;

    function setRecipient(uint16 centrifugeId, bytes32 recipient) external {
        centrifugeRecipients[centrifugeId] = recipient;
    }

    // setDomainParameters(uint32,bytes32,uint32,uint32) — CCTP
    struct CCTPDomain {
        bytes32 recipient;
        uint32  minFeeCapRate;
        uint32  maxFeeCapRate;
    }
    mapping(uint32 => CCTPDomain) public cctpDomains;

    function setDomainParameters(
        uint32  destinationDomain,
        bytes32 recipient,
        uint32  minFeeCapRate,
        uint32  maxFeeCapRate
    ) external {
        cctpDomains[destinationDomain] = CCTPDomain(recipient, minFeeCapRate, maxFeeCapRate);
    }

    // setMaxExchangeRate(address,uint256,uint256) — ERC4626
    struct ExchangeRate {
        uint256 shares;
        uint256 maxExpectedAssets;
    }
    mapping(address => ExchangeRate) public exchangeRates;

    function setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external {
        exchangeRates[token] = ExchangeRate(shares, maxExpectedAssets);
    }

    // approve(address,uint256) — OTCBuffer
    mapping(address => uint256) public approvals;

    function approve(address asset, uint256 allowance) external {
        approvals[asset] = allowance;
    }

    // setBuffer(address,address) — OTCFacet
    mapping(address => address) public buffers;

    function setBuffer(address exchange, address buffer) external {
        buffers[exchange] = buffer;
    }

    // setRechargeRate(address,uint256) — OTCFacet
    mapping(address => uint256) public rechargeRates;

    function setRechargeRate(address exchange, uint256 normalizedRate) external {
        rechargeRates[exchange] = normalizedRate;
    }

    // setMaxTickDelta(address,uint24) — UniswapV3
    mapping(address => uint24) public maxTickDeltas;

    function setMaxTickDelta(address pool, uint24 maxTickDelta) external {
        maxTickDeltas[pool] = maxTickDelta;
    }

    // setLiquidityLowerTickBound(address,int24) — UniswapV3
    mapping(address => int24) public liquidityLowerTicks;

    function setLiquidityLowerTickBound(address pool, int24 lowerTickBound) external {
        liquidityLowerTicks[pool] = lowerTickBound;
    }

    // setLiquidityUpperTickBound(address,int24) — UniswapV3
    mapping(address => int24) public liquidityUpperTicks;

    function setLiquidityUpperTickBound(address pool, int24 upperTickBound) external {
        liquidityUpperTicks[pool] = upperTickBound;
    }

    // setTWAPSecondsAgo(address,uint32) — UniswapV3
    mapping(address => uint32) public twapSecondsAgos;

    function setTWAPSecondsAgo(address pool, uint32 twapSecondsAgo) external {
        twapSecondsAgos[pool] = twapSecondsAgo;
    }

    // setTickLimits(bytes32,int24,int24,uint24) — UniswapV4
    struct TickLimits {
        int24  tickLowerMin;
        int24  tickUpperMax;
        uint24 maxTickSpacing;
    }
    mapping(bytes32 => TickLimits) public tickLimits;

    function setTickLimits(
        bytes32 poolId,
        int24   tickLowerMin,
        int24   tickUpperMax,
        uint24  maxTickSpacing
    ) external {
        tickLimits[poolId] = TickLimits(tickLowerMin, tickUpperMax, maxTickSpacing);
    }

    // setVault(address) — USDS
    address public vault;

    function setVault(address vault_) external {
        vault = vault_;
    }
}
