// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Configurator.spec -- Formal verification spec for Configurator

using Configurator as configurator;
using BeamState as beamState;
using RateLimitsHarness as rateLimitsHarness;

// --- Methods block ---

methods {
    // Configurator storage getters
    function zzz(address, bytes32) external returns (uint256) envfree;

    // Configurator immutable getter
    function beamState() external returns (address) envfree;

    // BeamState functions used by Configurator
    function beamState.stopped() external returns (bool) envfree;
    function beamState.rateLimitsCBeams(address, address) external returns (uint256) envfree;
    function beamState.controllersCBeams(address, address) external returns (uint256) envfree;
    function beamState.getHop(address) external returns (uint256) envfree;
    function beamState.getMaxChange(address) external returns (uint256) envfree;
    function beamState.getInitRateLimits(bytes32, address) external returns (BeamState.DefaultRateLimits) envfree;
    function beamState.isControllerActionEnabled(bytes32, address) external returns (bool) envfree;

    // RateLimitsHarness functions
    function rateLimitsHarness.getMaxAmount(bytes32) external returns (uint256) envfree;
    function rateLimitsHarness.getSlope(bytes32) external returns (uint256) envfree;
    function rateLimitsHarness.getLastAmount(bytes32) external returns (uint256) envfree;
    function rateLimitsHarness.getLastUpdated(bytes32) external returns (uint256) envfree;

    function _.getRateLimitData(bytes32) external => DISPATCHER(true);
    function _.getCurrentRateLimit(bytes32) external => DISPATCHER(true);
    function _.setRateLimitData(bytes32, uint256, uint256, uint256, uint256) external => DISPATCHER(true);
    function _.setUnlimitedRateLimitData(bytes32) external => DISPATCHER(true);
}

// --- Definitions ---

definition WAD() returns mathint = 10^18;

// Helper to compute max of two values
definition _max(uint256 x, uint256 y) returns uint256 = x > y ? x : y;

// Helper to compute min of two values
definition _min(uint256 x, uint256 y) returns uint256 = x < y ? x : y;

// --- Storage Affected Rule ---

rule storageAffected(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;

    address anyAddr;
    bytes32 anyKey;

    uint256 zzzBefore = zzz(anyAddr, anyKey);

    f(e, args);

    uint256 zzzAfter = zzz(anyAddr, anyKey);

    assert zzzAfter != zzzBefore =>
        f.selector == sig:setRateLimit(address, bytes32, uint256, uint256).selector;
}

// --- setRateLimit rules ---

// Verifies that setRateLimit correctly handles the unlimited case
rule setRateLimit_unlimited(bytes32 key, uint256 maxAmount, uint256 slope) {
    env e;

    // Setup: unlimited defaults (maxAmount == type(uint256).max && slope == 0)
    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);
    require defLimits.maxAmount == max_uint256;
    require defLimits.slope == 0;

    // Pre-state
    uint256 zzzBefore = zzz(rateLimitsHarness, key);

    setRateLimit(e, rateLimitsHarness, key, maxAmount, slope);

    // Post-state
    uint256 maxAmountAfter  = rateLimitsHarness.getMaxAmount(key);
    uint256 slopeAfter      = rateLimitsHarness.getSlope(key);
    uint256 lastAmountAfter = rateLimitsHarness.getLastAmount(key);
    uint256 zzzAfter        = zzz(rateLimitsHarness, key);

    // When unlimited: setUnlimitedRateLimitData sets maxAmount = max_uint256, slope = 0, lastAmount = max_uint256
    assert maxAmountAfter == max_uint256;
    assert slopeAfter == 0;
    assert lastAmountAfter == max_uint256;
    // zzz should NOT be updated for unlimited
    assert zzzAfter == zzzBefore;
}

// Verifies that setRateLimit correctly handles decrements (no hop required, zzz not updated)
rule setRateLimit_decrement(bytes32 key, uint256 maxAmount, uint256 slope) {
    env e;

    // Setup: NOT unlimited defaults
    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);
    require !(defLimits.maxAmount == max_uint256 && defLimits.slope == 0);

    // Current values
    uint256 currentMaxAmount = rateLimitsHarness.getMaxAmount(key);
    uint256 currentSlope     = rateLimitsHarness.getSlope(key);

    // This is a decrement (both params <= current)
    require maxAmount <= currentMaxAmount;
    require slope <= currentSlope;

    // Pre-state
    uint256 zzzBefore = zzz(rateLimitsHarness, key);

    setRateLimit(e, rateLimitsHarness, key, maxAmount, slope);

    // Post-state
    uint256 maxAmountAfter = rateLimitsHarness.getMaxAmount(key);
    uint256 slopeAfter     = rateLimitsHarness.getSlope(key);
    uint256 zzzAfter       = zzz(rateLimitsHarness, key);

    // Values should be set as requested
    assert maxAmountAfter == maxAmount;
    assert slopeAfter == slope;
    // zzz should NOT be updated on decrement
    assert zzzAfter == zzzBefore;
}

// Verifies that setRateLimit correctly handles increments (hop required, zzz updated)
rule setRateLimit_increment(bytes32 key, uint256 maxAmount, uint256 slope) {
    env e;

    // Setup: NOT unlimited defaults
    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);
    require !(defLimits.maxAmount == max_uint256 && defLimits.slope == 0);

    // Current values
    uint256 currentMaxAmount = rateLimitsHarness.getMaxAmount(key);
    uint256 currentSlope     = rateLimitsHarness.getSlope(key);

    // This is an increment (at least one param > current)
    require maxAmount > currentMaxAmount || slope > currentSlope;

    setRateLimit(e, rateLimitsHarness, key, maxAmount, slope);

    // Post-state
    uint256 maxAmountAfter = rateLimitsHarness.getMaxAmount(key);
    uint256 slopeAfter     = rateLimitsHarness.getSlope(key);
    uint256 zzzAfter       = zzz(rateLimitsHarness, key);

    // Values should be set as requested
    assert maxAmountAfter == maxAmount;
    assert slopeAfter == slope;
    // zzz should be updated to block.timestamp on increment
    assert zzzAfter == e.block.timestamp;
}

// Verifies that lastAmount is set correctly (min of maxAmount and currentRateLimit)
rule setRateLimit_lastAmount(bytes32 key, uint256 maxAmount, uint256 slope) {
    env e;

    // Setup: NOT unlimited defaults
    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);
    require !(defLimits.maxAmount == max_uint256 && defLimits.slope == 0);

    // Get currentRateLimit before the call
    uint256 currentRateLimit = rateLimitsHarness.getCurrentRateLimit(e, key);

    setRateLimit(e, rateLimitsHarness, key, maxAmount, slope);

    // Post-state
    uint256 lastAmountAfter  = rateLimitsHarness.getLastAmount(key);
    uint256 lastUpdatedAfter = rateLimitsHarness.getLastUpdated(key);

    // lastAmount = _min(maxAmount, currentRateLimit)
    assert lastAmountAfter == _min(maxAmount, currentRateLimit);
    // lastUpdated should be set to block.timestamp
    assert lastUpdatedAfter == e.block.timestamp;
}

// Verifies zzz is not updated for other (rateLimits_, key) pairs
rule setRateLimit_zzz_no_side_effects(bytes32 key, uint256 maxAmount, uint256 slope) {
    env e;

    address otherRl;
    bytes32 otherKey;
    require otherRl != rateLimitsHarness || otherKey != key;

    uint256 zzzOtherBefore = zzz(otherRl, otherKey);

    setRateLimit(e, rateLimitsHarness, key, maxAmount, slope);

    uint256 zzzOtherAfter = zzz(otherRl, otherKey);

    assert zzzOtherAfter == zzzOtherBefore;
}

// Verifies that rateLimitsHarness data is not modified for other keys
rule setRateLimit_rateLimits_no_side_effects(bytes32 key, uint256 maxAmount, uint256 slope) {
    env e;

    bytes32 otherKey;
    require otherKey != key;

    uint256 otherMaxAmountBefore   = rateLimitsHarness.getMaxAmount(otherKey);
    uint256 otherSlopeBefore       = rateLimitsHarness.getSlope(otherKey);
    uint256 otherLastAmountBefore  = rateLimitsHarness.getLastAmount(otherKey);
    uint256 otherLastUpdatedBefore = rateLimitsHarness.getLastUpdated(otherKey);

    setRateLimit(e, rateLimitsHarness, key, maxAmount, slope);

    uint256 otherMaxAmountAfter   = rateLimitsHarness.getMaxAmount(otherKey);
    uint256 otherSlopeAfter       = rateLimitsHarness.getSlope(otherKey);
    uint256 otherLastAmountAfter  = rateLimitsHarness.getLastAmount(otherKey);
    uint256 otherLastUpdatedAfter = rateLimitsHarness.getLastUpdated(otherKey);

    assert otherMaxAmountAfter == otherMaxAmountBefore;
    assert otherSlopeAfter == otherSlopeBefore;
    assert otherLastAmountAfter == otherLastAmountBefore;
    assert otherLastUpdatedAfter == otherLastUpdatedBefore;
}

// --- Revert rules ---

rule setRateLimit_revert(bytes32 key, uint256 maxAmount, uint256 slope) {
    env e;

    bool stopped = beamState.stopped();
    uint256 rateLimitsCBeamsSender = beamState.rateLimitsCBeams(rateLimitsHarness, e.msg.sender);

    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);
    uint256 defMaxAmount = defLimits.maxAmount;
    uint256 defSlope     = defLimits.slope;

    uint256 currentMaxAmount   = rateLimitsHarness.getMaxAmount(key);
    uint256 currentSlope       = rateLimitsHarness.getSlope(key);
    uint256 currentLastUpdated = rateLimitsHarness.getLastUpdated(key);
    uint256 currentLastAmount  = rateLimitsHarness.getLastAmount(key);

    uint256 hop_       = beamState.getHop(rateLimitsHarness);
    uint256 maxChange_ = beamState.getMaxChange(rateLimitsHarness);
    uint256 zzzValue   = zzz(rateLimitsHarness, key);

    bool isUnlimited = defMaxAmount == max_uint256 && defSlope == 0;
    bool isIncrement = maxAmount > currentMaxAmount || slope > currentSlope;

    // Avoid overflows
    require currentMaxAmount * maxChange_ <= max_uint256;
    require currentSlope * maxChange_ <= max_uint256;
    require zzzValue + hop_ <= max_uint256 || zzzValue + hop_ >= zzzValue;
    require e.block.timestamp >= currentLastUpdated;
    require currentSlope * (e.block.timestamp - currentLastUpdated) + currentLastAmount <= max_uint256;

    setRateLimit@withrevert(e, rateLimitsHarness, key, maxAmount, slope);

    bool revert1 = e.msg.value > 0;
    bool revert2 = stopped;
    bool revert3 = rateLimitsCBeamsSender != 1;
    bool revert4 = isUnlimited && !(maxAmount == max_uint256 && slope == 0);
    bool revert5 = !isUnlimited && maxAmount > _max(require_uint256(currentMaxAmount * maxChange_ / WAD()), defMaxAmount);
    bool revert6 = !isUnlimited && slope > _max(require_uint256(currentSlope * maxChange_ / WAD()), defSlope);
    bool revert7 = !isUnlimited && isIncrement && hop_ == 0;
    bool revert8 = !isUnlimited && isIncrement && e.block.timestamp < zzzValue + hop_;

    assert lastReverted <=> revert1 || revert2 || revert3 || revert4 || revert5 || revert6 || revert7 || revert8;
}

// --- callControllerAction rules ---

rule callControllerAction_revert(address controller, bytes data) {
    env e;

    bool    stopped                   = beamState.stopped();
    uint256 controllersCBeamsSender   = beamState.controllersCBeams(controller, e.msg.sender);
    bool    isControllerActionEnabled = beamState.isControllerActionEnabled(keccak256(data), controller);

    callControllerAction@withrevert(e, controller, data);

    bool revert1 = e.msg.value > 0;
    bool revert2 = stopped;
    bool revert3 = controllersCBeamsSender != 1;
    bool revert4 = !isControllerActionEnabled;

    // Note: Additional revert from external controller call is not covered here
    assert revert1 || revert2 || revert3 || revert4 => lastReverted;
}

// When stopped, all non-view functions revert
rule whenStoppedAllFunctionsRevert(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;

    require beamState.stopped();

    f@withrevert(e, args);

    assert lastReverted;
}
