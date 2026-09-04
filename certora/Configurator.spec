// Configurator.spec

using Configurator as configurator;
using BeamState as beamState;
using RateLimitsHarness as rateLimitsHarness;
using ControllerHarness as controllerHarness;

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

    // ControllerHarness functions
    function controllerHarness.calls() external returns (uint256) envfree;

    function _.getRateLimitData(bytes32) external => DISPATCHER(true);
    function _.getCurrentRateLimit(bytes32) external => DISPATCHER(true);
    function _.setRateLimitData(bytes32, uint256, uint256, uint256, uint256) external => DISPATCHER(true);
    function _.setUnlimitedRateLimitData(bytes32) external => DISPATCHER(true);

    // Configurator forwards a low-level call with symbolic calldata to an arbitrary controller.
    // optimistic=true replaces the fallthrough branch with ASSUME FALSE, forcing the call to resolve
    // to ControllerHarness.action() instead of letting the solver escape through `default`.
    // use_fallback=true routes every non-matching sighash to the harness fallback, so `data` stays
    // fully symbolic instead of being pinned to action()'s selector.
    // Neither harness entry point can revert (the increments are unchecked), so `require(ok)` is
    // proven not to fire rather than assumed away.
    unresolved external in Configurator.callControllerAction(address, bytes) => DISPATCH(optimistic=true) [
        ControllerHarness.action()
    ];
}

// --- Definitions ---

definition WAD() returns mathint = 10^18;

// Helper to compute min of two values
definition _min(uint256 x, uint256 y) returns uint256 = x < y ? x : y;

// Mirrors the contract's unlimited branch condition:
//   defMaxAmount == type(uint256).max && defSlope == 0 ||
//   current.maxAmount == type(uint256).max && current.slope == 0 && defMaxAmount == 0 && defSlope == 0
definition isUnlimited(uint256 defMaxAmount, uint256 defSlope, uint256 curMaxAmount, uint256 curSlope) returns bool =
    (defMaxAmount == max_uint256 && defSlope == 0) ||
    (curMaxAmount == max_uint256 && curSlope == 0 && defMaxAmount == 0 && defSlope == 0);

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

// Verifies that setRateLimit correctly handles the unlimited case, covering both the
// BeamState-registered branch and the pre-existing-unlimited-key branch
rule setRateLimit_unlimited(bytes32 key, uint256 maxAmount, uint256 slope) {
    env e;

    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);
    uint256 currentMaxAmount = rateLimitsHarness.getMaxAmount(key);
    uint256 currentSlope     = rateLimitsHarness.getSlope(key);

    // Setup: the key is locked as unlimited
    require isUnlimited(defLimits.maxAmount, defLimits.slope, currentMaxAmount, currentSlope);

    // Pre-state
    uint256 zzzBefore = zzz(rateLimitsHarness, key);

    setRateLimit(e, rateLimitsHarness, key, maxAmount, slope);

    // Post-state
    uint256 maxAmountAfter  = rateLimitsHarness.getMaxAmount(key);
    uint256 slopeAfter      = rateLimitsHarness.getSlope(key);
    uint256 lastAmountAfter = rateLimitsHarness.getLastAmount(key);
    uint256 zzzAfter        = zzz(rateLimitsHarness, key);

    // A successful call on a locked key can only have carried (max, 0): it can never be lowered
    assert maxAmount == max_uint256 && slope == 0;
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

    // Setup: the key is NOT locked as unlimited
    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);

    // Current values
    uint256 currentMaxAmount = rateLimitsHarness.getMaxAmount(key);
    uint256 currentSlope     = rateLimitsHarness.getSlope(key);

    require !isUnlimited(defLimits.maxAmount, defLimits.slope, currentMaxAmount, currentSlope);

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

    // Setup: the key is NOT locked as unlimited
    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);

    // Current values
    uint256 currentMaxAmount = rateLimitsHarness.getMaxAmount(key);
    uint256 currentSlope     = rateLimitsHarness.getSlope(key);

    require !isUnlimited(defLimits.maxAmount, defLimits.slope, currentMaxAmount, currentSlope);

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

    // Setup: the key is NOT locked as unlimited
    BeamState.DefaultRateLimits defLimits = beamState.getInitRateLimits(key, rateLimitsHarness);
    require !isUnlimited(
        defLimits.maxAmount, defLimits.slope,
        rateLimitsHarness.getMaxAmount(key), rateLimitsHarness.getSlope(key)
    );

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

    bool isUnlimited_ = isUnlimited(defMaxAmount, defSlope, currentMaxAmount, currentSlope);
    bool isIncrement  = maxAmount > currentMaxAmount || slope > currentSlope;

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
    bool revert4 = isUnlimited_ && !(maxAmount == max_uint256 && slope == 0);
    // Negation of the contract's 3-way OR:
    //   maxAmount <= defMaxAmount || maxAmount <= current.maxAmount || maxAmount <= current.maxAmount * maxChange / WAD
    bool revert5 = !isUnlimited_ && maxAmount > defMaxAmount
                                 && maxAmount > currentMaxAmount
                                 && maxAmount > require_uint256(currentMaxAmount * maxChange_ / WAD());
    bool revert6 = !isUnlimited_ && slope > defSlope
                                 && slope > currentSlope
                                 && slope > require_uint256(currentSlope * maxChange_ / WAD());
    bool revert7 = !isUnlimited_ && isIncrement && hop_ == 0;
    bool revert8 = !isUnlimited_ && isIncrement && e.block.timestamp < zzzValue + hop_;

    assert lastReverted <=> revert1 || revert2 || revert3 || revert4 || revert5 || revert6 || revert7 || revert8;
}

// --- callControllerAction rules ---

rule callControllerAction(address controller, bytes data) {
    env e;

    require controllerHarness.calls() == 0;

    callControllerAction(e, controller, data);

    assert controllerHarness.calls() == 1;
}

// Exhaustive revert conditions. The controller call is dispatched to ControllerHarness.action(),
// which never reverts, so `require(ok)` is not an additional revert cause here.
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

    assert lastReverted <=> revert1 || revert2 || revert3 || revert4;
}
