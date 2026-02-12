// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// BeamState.spec -- Formal verification spec for BeamState

using BeamState as beamState;

// --- Methods block ---

methods {
    // Storage getters
    function wards(address)                          external returns (uint256) envfree;
    function userRoles(address)                      external returns (bytes32) envfree;
    function actionsRoles(bytes4)                    external returns (bytes32) envfree;
    function rateLimits(address)                     external returns (uint256) envfree;
    function controllers(address)                    external returns (uint256) envfree;
    function cBeams(address)                         external returns (uint256) envfree;
    function rateLimitsCBeams(address, address)      external returns (uint256) envfree;
    function controllersCBeams(address, address)     external returns (uint256) envfree;
    function initRateLimits(bytes32, address)        external returns (uint256, uint256) envfree;
    function initControllerActions(bytes32, address) external returns (uint256) envfree;
    function hop(address)                            external returns (uint256) envfree;
    function maxChange(address)                      external returns (uint256) envfree;
    function stopped()                               external returns (bool)    envfree;

    // View functions
    function hasUserRole(address, uint8)              external returns (bool)    envfree;
    function isActionInRole(bytes4, uint8)            external returns (bool)    envfree;
    function getHop(address)                          external returns (uint256) envfree;
    function getMaxChange(address)                    external returns (uint256) envfree;
    function getInitRateLimits(bytes32, address)      external returns (BeamState.DefaultRateLimits) envfree;
    function isControllerActionEnabled(bytes32, address) external returns (bool) envfree;
}

// --- Definitions ---

definition WAD() returns mathint = 10^18;

// --- Storage Affected Rule ---

rule storageAffected(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;

    address anyAddr;
    address anyAddr2;
    bytes4 anySig;
    bytes32 anyKey;

    uint256 wardsBefore                    = wards(anyAddr);
    bytes32 userRolesBefore                = userRoles(anyAddr);
    bytes32 actionsRolesBefore             = actionsRoles(anySig);
    bool    stoppedBefore                  = stopped();
    uint256 rateLimitsBefore               = rateLimits(anyAddr);
    uint256 controllersBefore              = controllers(anyAddr);
    uint256 cBeamsBefore                   = cBeams(anyAddr);
    uint256 rateLimitsCBeamsBefore         = rateLimitsCBeams(anyAddr, anyAddr2);
    uint256 controllersCBeamsBefore        = controllersCBeams(anyAddr, anyAddr2);
    uint256 hopBefore                      = hop(anyAddr);
    uint256 maxChangeBefore                = maxChange(anyAddr);
    uint256 initRateLimitsMaxAmountBefore;
    uint256 initRateLimitsSlopeBefore;
    initRateLimitsMaxAmountBefore, initRateLimitsSlopeBefore = initRateLimits(anyKey, anyAddr);
    uint256 initControllerActionsBefore    = initControllerActions(anyKey, anyAddr);

    f(e, args);

    uint256 wardsAfter                    = wards(anyAddr);
    bytes32 userRolesAfter                = userRoles(anyAddr);
    bytes32 actionsRolesAfter             = actionsRoles(anySig);
    bool    stoppedAfter                  = stopped();
    uint256 rateLimitsAfter               = rateLimits(anyAddr);
    uint256 controllersAfter              = controllers(anyAddr);
    uint256 cBeamsAfter                   = cBeams(anyAddr);
    uint256 rateLimitsCBeamsAfter         = rateLimitsCBeams(anyAddr, anyAddr2);
    uint256 controllersCBeamsAfter        = controllersCBeams(anyAddr, anyAddr2);
    uint256 hopAfter                      = hop(anyAddr);
    uint256 maxChangeAfter                = maxChange(anyAddr);
    uint256 initRateLimitsMaxAmountAfter;
    uint256 initRateLimitsSlopeAfter;
    initRateLimitsMaxAmountAfter, initRateLimitsSlopeAfter = initRateLimits(anyKey, anyAddr);
    uint256 initControllerActionsAfter    = initControllerActions(anyKey, anyAddr);

    assert wardsAfter != wardsBefore =>
        f.selector == sig:rely(address).selector ||
        f.selector == sig:deny(address).selector;
    assert userRolesAfter != userRolesBefore =>
        f.selector == sig:setUserRole(address, uint8, bool).selector;
    assert actionsRolesAfter != actionsRolesBefore =>
        f.selector == sig:setRoleAction(uint8, bytes4, bool).selector;
    assert stoppedAfter != stoppedBefore =>
        f.selector == sig:stop().selector ||
        f.selector == sig:start().selector;
    assert rateLimitsAfter != rateLimitsBefore =>
        f.selector == sig:addRateLimits(address).selector ||
        f.selector == sig:delRateLimits(address).selector;
    assert controllersAfter != controllersBefore =>
        f.selector == sig:addController(address).selector ||
        f.selector == sig:delController(address).selector;
    assert cBeamsAfter != cBeamsBefore =>
        f.selector == sig:addCBeam(address).selector ||
        f.selector == sig:delCBeam(address).selector;
    assert rateLimitsCBeamsAfter != rateLimitsCBeamsBefore =>
        f.selector == sig:setCBeamForRateLimits(address, address).selector ||
        f.selector == sig:unsetCBeamForRateLimits(address, address).selector;
    assert controllersCBeamsAfter != controllersCBeamsBefore =>
        f.selector == sig:setCBeamForController(address, address).selector ||
        f.selector == sig:unsetCBeamForController(address, address).selector;
    assert hopAfter != hopBefore =>
        f.selector == sig:setHop(address, uint256).selector;
    assert maxChangeAfter != maxChangeBefore =>
        f.selector == sig:setMaxChange(address, uint256).selector;
    assert (initRateLimitsMaxAmountAfter != initRateLimitsMaxAmountBefore || initRateLimitsSlopeAfter != initRateLimitsSlopeBefore) =>
        f.selector == sig:addInitRateLimits(bytes32, address, uint256, uint256).selector ||
        f.selector == sig:delInitRateLimits(bytes32, address).selector;
    assert initControllerActionsAfter != initControllerActionsBefore =>
        f.selector == sig:addInitControllerActions(bytes, address).selector ||
        f.selector == sig:delInitControllerActions(bytes32, address).selector;
}

// --- Invariants ---

// Binary value invariants
invariant wardsIsBinary(address usr)
    wards(usr) == 0 || wards(usr) == 1;

invariant rateLimitsIsBinary(address rl)
    rateLimits(rl) == 0 || rateLimits(rl) == 1;

invariant controllersIsBinary(address c)
    controllers(c) == 0 || controllers(c) == 1;

invariant cBeamsIsBinary(address cb)
    cBeams(cb) == 0 || cBeams(cb) == 1;

invariant rateLimitsCBeamsIsBinary(address rl, address cb)
    rateLimitsCBeams(rl, cb) == 0 || rateLimitsCBeams(rl, cb) == 1;

invariant controllersCBeamsIsBinary(address c, address cb)
    controllersCBeams(c, cb) == 0 || controllersCBeams(c, cb) == 1;

invariant initControllerActionsIsBinary(bytes32 key, address c)
    initControllerActions(key, c) == 0 || initControllerActions(key, c) == 1;

// maxChange must be >= WAD when set (enforced by setMaxChange require)
invariant maxChangeMinimum(address rl)
    maxChange(rl) == 0 || maxChange(rl) >= WAD();

// --- View function correctness ---

// hasUserRole correctly checks the bit in userRoles
rule hasUserRoleCorrectness(address usr, uint8 role) {
    bytes32 userRolesUsr = userRoles(usr);
    bytes32 mask         = to_bytes32(assert_uint256(2 ^ role));
    bool result          = hasUserRole(usr, role);

    assert result <=> (userRolesUsr & mask != to_bytes32(0));
}

// isActionInRole correctly checks the bit in actionsRoles
rule isActionInRoleCorrectness(bytes4 sig_, uint8 role) {
    bytes32 actionsRolesSig = actionsRoles(sig_);
    bytes32 mask            = to_bytes32(assert_uint256(2 ^ role));
    bool result             = isActionInRole(sig_, role);

    assert result <=> (actionsRolesSig & mask != to_bytes32(0));
}

// getHop returns hop[rl] if set, otherwise falls back to hop[address(0)]
rule getHopCorrectness(address rl) {
    uint256 hopRl   = hop(rl);
    uint256 hopZero = hop(0);
    uint256 result  = getHop(rl);

    assert hopRl != 0 => result == hopRl;
    assert hopRl == 0 => result == hopZero;
}

// getMaxChange returns maxChange[rl] if set, otherwise falls back to maxChange[address(0)]
rule getMaxChangeCorrectness(address rl) {
    uint256 maxChangeRl   = maxChange(rl);
    uint256 maxChangeZero = maxChange(0);
    uint256 result        = getMaxChange(rl);

    assert maxChangeRl != 0 => result == maxChangeRl;
    assert maxChangeRl == 0 => result == maxChangeZero;
}

// isControllerActionEnabled checks address(0) OR specific controller
rule isControllerActionEnabledCorrectness(bytes32 key, address controller) {
    uint256 initControllerActionsKeyZero       = initControllerActions(key, 0);
    uint256 initControllerActionsKeyController = initControllerActions(key, controller);
    bool result                                = isControllerActionEnabled(key, controller);

    assert result <=> (initControllerActionsKeyZero == 1 || initControllerActionsKeyController == 1);
}

// --- Auth functions: rely ---

rule rely(address usr) {
    env e;

    address other;
    require other != usr;

    uint256 wardsOtherBefore = wards(other);

    rely(e, usr);

    uint256 wardsUsrAfter   = wards(usr);
    uint256 wardsOtherAfter = wards(other);

    assert wardsUsrAfter == 1;
    assert wardsOtherAfter == wardsOtherBefore;
}

rule rely_revert(address usr) {
    env e;

    uint256 wardsSender = wards(e.msg.sender);

    rely@withrevert(e, usr);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- Auth functions: deny ---

rule deny(address usr) {
    env e;

    address other;
    require other != usr;

    uint256 wardsOtherBefore = wards(other);

    deny(e, usr);

    uint256 wardsUsrAfter   = wards(usr);
    uint256 wardsOtherAfter = wards(other);

    assert wardsUsrAfter == 0;
    assert wardsOtherAfter == wardsOtherBefore;
}

rule deny_revert(address usr) {
    env e;

    uint256 wardsSender = wards(e.msg.sender);

    deny@withrevert(e, usr);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- Auth functions: setUserRole ---

rule setUserRole(address who, uint8 role, bool enabled) {
    env e;

    address other;
    require other != who;

    bytes32 userRolesWhoBefore   = userRoles(who);
    bytes32 userRolesOtherBefore = userRoles(other);

    bytes32 mask = to_bytes32(assert_uint256(2 ^ role));
    bytes32 expectedUserRolesWho;
    if (enabled) {
        expectedUserRolesWho = userRolesWhoBefore | mask;
    } else {
        expectedUserRolesWho = userRolesWhoBefore & ~mask;
    }

    setUserRole(e, who, role, enabled);

    bytes32 userRolesWhoAfter   = userRoles(who);
    bytes32 userRolesOtherAfter = userRoles(other);

    assert userRolesWhoAfter == expectedUserRolesWho;
    assert userRolesOtherAfter == userRolesOtherBefore;
}

rule setUserRole_revert(address who, uint8 role, bool enabled) {
    env e;

    uint256 wardsSender = wards(e.msg.sender);

    setUserRole@withrevert(e, who, role, enabled);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- Auth functions: setRoleAction ---

rule setRoleAction(uint8 role, bytes4 sig_, bool enabled) {
    env e;

    bytes4 otherSig;
    require otherSig != sig_;

    bytes32 actionsRolesSigBefore      = actionsRoles(sig_);
    bytes32 actionsRolesOtherSigBefore = actionsRoles(otherSig);

    bytes32 mask = to_bytes32(assert_uint256(2 ^ role));
    bytes32 expectedActionsRolesSig;
    if (enabled) {
        expectedActionsRolesSig = actionsRolesSigBefore | mask;
    } else {
        expectedActionsRolesSig = actionsRolesSigBefore & ~mask;
    }

    setRoleAction(e, role, sig_, enabled);

    bytes32 actionsRolesSigAfter      = actionsRoles(sig_);
    bytes32 actionsRolesOtherSigAfter = actionsRoles(otherSig);

    assert actionsRolesSigAfter == expectedActionsRolesSig;
    assert actionsRolesOtherSigAfter == actionsRolesOtherSigBefore;
}

rule setRoleAction_revert(uint8 role, bytes4 sig_, bool enabled) {
    env e;

    uint256 wardsSender = wards(e.msg.sender);

    setRoleAction@withrevert(e, role, sig_, enabled);

    bool revert1 = e.msg.value > 0;
    bool revert2 = wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: stop ---

rule stop() {
    env e;

    stop(e);

    assert stopped() == true;
}

rule stop_revert() {
    env e;

    uint256 wardsSender       = wards(e.msg.sender);
    bytes32 userRolesSender   = userRoles(e.msg.sender);
    bytes32 actionsRolesStop  = actionsRoles(to_bytes4(sig:stop().selector));

    stop@withrevert(e);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesStop == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: start ---

rule start() {
    env e;

    start(e);

    assert stopped() == false;
}

rule start_revert() {
    env e;

    uint256 wardsSender       = wards(e.msg.sender);
    bytes32 userRolesSender   = userRoles(e.msg.sender);
    bytes32 actionsRolesStart = actionsRoles(to_bytes4(sig:start().selector));

    start@withrevert(e);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesStart == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: setHop ---

rule setHop(address rateLimits_, uint256 value) {
    env e;

    address other;
    require other != rateLimits_;

    uint256 hopOtherBefore = hop(other);

    setHop(e, rateLimits_, value);

    uint256 hopRateLimitsAfter = hop(rateLimits_);
    uint256 hopOtherAfter      = hop(other);

    assert hopRateLimitsAfter == value;
    assert hopOtherAfter == hopOtherBefore;
}

rule setHop_revert(address rateLimits_, uint256 value) {
    env e;

    uint256 wardsSender        = wards(e.msg.sender);
    bytes32 userRolesSender    = userRoles(e.msg.sender);
    bytes32 actionsRolesSetHop = actionsRoles(to_bytes4(sig:setHop(address, uint256).selector));

    setHop@withrevert(e, rateLimits_, value);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesSetHop == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: setMaxChange ---

rule setMaxChange(address rateLimits_, uint256 value) {
    env e;

    address other;
    require other != rateLimits_;

    uint256 maxChangeOtherBefore = maxChange(other);

    setMaxChange(e, rateLimits_, value);

    uint256 maxChangeRateLimitsAfter = maxChange(rateLimits_);
    uint256 maxChangeOtherAfter      = maxChange(other);

    assert maxChangeRateLimitsAfter == value;
    assert maxChangeOtherAfter == maxChangeOtherBefore;
}

rule setMaxChange_revert(address rateLimits_, uint256 value) {
    env e;

    uint256 wardsSender              = wards(e.msg.sender);
    bytes32 userRolesSender          = userRoles(e.msg.sender);
    bytes32 actionsRolesSetMaxChange = actionsRoles(to_bytes4(sig:setMaxChange(address, uint256).selector));

    setMaxChange@withrevert(e, rateLimits_, value);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesSetMaxChange == to_bytes32(0)) && wardsSender != 1;
    bool revert3 = value < WAD();

    assert lastReverted <=> revert1 || revert2 || revert3;
}

// --- RoleAuth functions: addRateLimits ---

rule addRateLimits(address rateLimits_) {
    env e;

    address other;
    require other != rateLimits_;

    uint256 rateLimitsOtherBefore = rateLimits(other);

    addRateLimits(e, rateLimits_);

    uint256 rateLimitsRateLimitsAfter = rateLimits(rateLimits_);
    uint256 rateLimitsOtherAfter      = rateLimits(other);

    assert rateLimitsRateLimitsAfter == 1;
    assert rateLimitsOtherAfter == rateLimitsOtherBefore;
}

rule addRateLimits_revert(address rateLimits_) {
    env e;

    uint256 wardsSender               = wards(e.msg.sender);
    bytes32 userRolesSender           = userRoles(e.msg.sender);
    bytes32 actionsRolesAddRateLimits = actionsRoles(to_bytes4(sig:addRateLimits(address).selector));

    addRateLimits@withrevert(e, rateLimits_);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesAddRateLimits == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: delRateLimits ---

rule delRateLimits(address rateLimits_) {
    env e;

    address other;
    require other != rateLimits_;

    uint256 rateLimitsOtherBefore = rateLimits(other);

    delRateLimits(e, rateLimits_);

    uint256 rateLimitsRateLimitsAfter = rateLimits(rateLimits_);
    uint256 rateLimitsOtherAfter      = rateLimits(other);

    assert rateLimitsRateLimitsAfter == 0;
    assert rateLimitsOtherAfter == rateLimitsOtherBefore;
}

rule delRateLimits_revert(address rateLimits_) {
    env e;

    uint256 wardsSender               = wards(e.msg.sender);
    bytes32 userRolesSender           = userRoles(e.msg.sender);
    bytes32 actionsRolesDelRateLimits = actionsRoles(to_bytes4(sig:delRateLimits(address).selector));

    delRateLimits@withrevert(e, rateLimits_);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesDelRateLimits == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: addController ---

rule addController(address controller) {
    env e;

    address other;
    require other != controller;

    uint256 controllersOtherBefore = controllers(other);

    addController(e, controller);

    uint256 controllersControllerAfter = controllers(controller);
    uint256 controllersOtherAfter      = controllers(other);

    assert controllersControllerAfter == 1;
    assert controllersOtherAfter == controllersOtherBefore;
}

rule addController_revert(address controller) {
    env e;

    uint256 wardsSender               = wards(e.msg.sender);
    bytes32 userRolesSender           = userRoles(e.msg.sender);
    bytes32 actionsRolesAddController = actionsRoles(to_bytes4(sig:addController(address).selector));

    addController@withrevert(e, controller);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesAddController == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: delController ---

rule delController(address controller) {
    env e;

    address other;
    require other != controller;

    uint256 controllersOtherBefore = controllers(other);

    delController(e, controller);

    uint256 controllersControllerAfter = controllers(controller);
    uint256 controllersOtherAfter      = controllers(other);

    assert controllersControllerAfter == 0;
    assert controllersOtherAfter == controllersOtherBefore;
}

rule delController_revert(address controller) {
    env e;

    uint256 wardsSender               = wards(e.msg.sender);
    bytes32 userRolesSender           = userRoles(e.msg.sender);
    bytes32 actionsRolesDelController = actionsRoles(to_bytes4(sig:delController(address).selector));

    delController@withrevert(e, controller);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesDelController == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: addCBeam ---

rule addCBeam(address cBeam) {
    env e;

    address other;
    require other != cBeam;

    uint256 cBeamsOtherBefore = cBeams(other);

    addCBeam(e, cBeam);

    uint256 cBeamsCBeamAfter = cBeams(cBeam);
    uint256 cBeamsOtherAfter = cBeams(other);

    assert cBeamsCBeamAfter == 1;
    assert cBeamsOtherAfter == cBeamsOtherBefore;
}

rule addCBeam_revert(address cBeam) {
    env e;

    uint256 wardsSender          = wards(e.msg.sender);
    bytes32 userRolesSender      = userRoles(e.msg.sender);
    bytes32 actionsRolesAddCBeam = actionsRoles(to_bytes4(sig:addCBeam(address).selector));

    addCBeam@withrevert(e, cBeam);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesAddCBeam == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: delCBeam ---

rule delCBeam(address cBeam) {
    env e;

    address other;
    require other != cBeam;

    uint256 cBeamsOtherBefore = cBeams(other);

    delCBeam(e, cBeam);

    uint256 cBeamsCBeamAfter = cBeams(cBeam);
    uint256 cBeamsOtherAfter = cBeams(other);

    assert cBeamsCBeamAfter == 0;
    assert cBeamsOtherAfter == cBeamsOtherBefore;
}

rule delCBeam_revert(address cBeam) {
    env e;

    uint256 wardsSender          = wards(e.msg.sender);
    bytes32 userRolesSender      = userRoles(e.msg.sender);
    bytes32 actionsRolesDelCBeam = actionsRoles(to_bytes4(sig:delCBeam(address).selector));

    delCBeam@withrevert(e, cBeam);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesDelCBeam == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: setCBeamForRateLimits ---

rule setCBeamForRateLimits(address rateLimits_, address cBeam) {
    env e;

    address otherRl;
    address otherCb;
    require otherRl != rateLimits_ || otherCb != cBeam;

    uint256 rateLimitsCBeamsOtherRlOtherCbBefore = rateLimitsCBeams(otherRl, otherCb);

    setCBeamForRateLimits(e, rateLimits_, cBeam);

    uint256 rateLimitsCBeamsRateLimitsCBeamAfter = rateLimitsCBeams(rateLimits_, cBeam);
    uint256 rateLimitsCBeamsOtherRlOtherCbAfter  = rateLimitsCBeams(otherRl, otherCb);

    assert rateLimitsCBeamsRateLimitsCBeamAfter == 1;
    assert rateLimitsCBeamsOtherRlOtherCbAfter == rateLimitsCBeamsOtherRlOtherCbBefore;
}

rule setCBeamForRateLimits_revert(address rateLimits_, address cBeam) {
    env e;

    uint256 wardsSender                       = wards(e.msg.sender);
    bytes32 userRolesSender                   = userRoles(e.msg.sender);
    bytes32 actionsRolesSetCBeamForRateLimits = actionsRoles(to_bytes4(sig:setCBeamForRateLimits(address, address).selector));
    uint256 rateLimitsRateLimits              = rateLimits(rateLimits_);
    uint256 cBeamsCBeam                       = cBeams(cBeam);

    setCBeamForRateLimits@withrevert(e, rateLimits_, cBeam);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesSetCBeamForRateLimits == to_bytes32(0)) && wardsSender != 1;
    bool revert3 = rateLimitsRateLimits != 1;
    bool revert4 = cBeamsCBeam != 1;

    assert lastReverted <=> revert1 || revert2 || revert3 || revert4;
}

// --- RoleAuth functions: unsetCBeamForRateLimits ---

rule unsetCBeamForRateLimits(address rateLimits_, address cBeam) {
    env e;

    address otherRl;
    address otherCb;
    require otherRl != rateLimits_ || otherCb != cBeam;

    uint256 rateLimitsCBeamsOtherRlOtherCbBefore = rateLimitsCBeams(otherRl, otherCb);

    unsetCBeamForRateLimits(e, rateLimits_, cBeam);

    uint256 rateLimitsCBeamsRateLimitsCBeamAfter = rateLimitsCBeams(rateLimits_, cBeam);
    uint256 rateLimitsCBeamsOtherRlOtherCbAfter  = rateLimitsCBeams(otherRl, otherCb);

    assert rateLimitsCBeamsRateLimitsCBeamAfter == 0;
    assert rateLimitsCBeamsOtherRlOtherCbAfter == rateLimitsCBeamsOtherRlOtherCbBefore;
}

rule unsetCBeamForRateLimits_revert(address rateLimits_, address cBeam) {
    env e;

    uint256 wardsSender                         = wards(e.msg.sender);
    bytes32 userRolesSender                     = userRoles(e.msg.sender);
    bytes32 actionsRolesUnsetCBeamForRateLimits = actionsRoles(to_bytes4(sig:unsetCBeamForRateLimits(address, address).selector));

    unsetCBeamForRateLimits@withrevert(e, rateLimits_, cBeam);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesUnsetCBeamForRateLimits == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: setCBeamForController ---

rule setCBeamForController(address controller, address cBeam) {
    env e;

    address otherC;
    address otherCb;
    require otherC != controller || otherCb != cBeam;

    uint256 controllersCBeamsOtherCOtherCbBefore = controllersCBeams(otherC, otherCb);

    setCBeamForController(e, controller, cBeam);

    uint256 controllersCBeamsControllerCBeamAfter = controllersCBeams(controller, cBeam);
    uint256 controllersCBeamsOtherCOtherCbAfter   = controllersCBeams(otherC, otherCb);

    assert controllersCBeamsControllerCBeamAfter == 1;
    assert controllersCBeamsOtherCOtherCbAfter == controllersCBeamsOtherCOtherCbBefore;
}

rule setCBeamForController_revert(address controller, address cBeam) {
    env e;

    uint256 wardsSender                       = wards(e.msg.sender);
    bytes32 userRolesSender                   = userRoles(e.msg.sender);
    bytes32 actionsRolesSetCBeamForController = actionsRoles(to_bytes4(sig:setCBeamForController(address, address).selector));
    uint256 controllersController             = controllers(controller);
    uint256 cBeamsCBeam                       = cBeams(cBeam);

    setCBeamForController@withrevert(e, controller, cBeam);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesSetCBeamForController == to_bytes32(0)) && wardsSender != 1;
    bool revert3 = controllersController != 1;
    bool revert4 = cBeamsCBeam != 1;

    assert lastReverted <=> revert1 || revert2 || revert3 || revert4;
}

// --- RoleAuth functions: unsetCBeamForController ---

rule unsetCBeamForController(address controller, address cBeam) {
    env e;

    address otherC;
    address otherCb;
    require otherC != controller || otherCb != cBeam;

    uint256 controllersCBeamsOtherCOtherCbBefore = controllersCBeams(otherC, otherCb);

    unsetCBeamForController(e, controller, cBeam);

    uint256 controllersCBeamsControllerCBeamAfter = controllersCBeams(controller, cBeam);
    uint256 controllersCBeamsOtherCOtherCbAfter   = controllersCBeams(otherC, otherCb);

    assert controllersCBeamsControllerCBeamAfter == 0;
    assert controllersCBeamsOtherCOtherCbAfter == controllersCBeamsOtherCOtherCbBefore;
}

rule unsetCBeamForController_revert(address controller, address cBeam) {
    env e;

    uint256 wardsSender                         = wards(e.msg.sender);
    bytes32 userRolesSender                     = userRoles(e.msg.sender);
    bytes32 actionsRolesUnsetCBeamForController = actionsRoles(to_bytes4(sig:unsetCBeamForController(address, address).selector));

    unsetCBeamForController@withrevert(e, controller, cBeam);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesUnsetCBeamForController == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: addInitRateLimits ---

rule addInitRateLimits(bytes32 key, address rateLimits_, uint256 maxAmount, uint256 slope) {
    env e;

    bytes32 otherKey;
    address otherRl;
    require otherKey != key || otherRl != rateLimits_;

    uint256 initRateLimitsOtherKeyOtherRlMaxAmountBefore;
    uint256 initRateLimitsOtherKeyOtherRlSlopeBefore;
    initRateLimitsOtherKeyOtherRlMaxAmountBefore, initRateLimitsOtherKeyOtherRlSlopeBefore = initRateLimits(otherKey, otherRl);

    addInitRateLimits(e, key, rateLimits_, maxAmount, slope);

    uint256 initRateLimitsKeyRateLimitsMaxAmountAfter;
    uint256 initRateLimitsKeyRateLimitsSlopeAfter;
    initRateLimitsKeyRateLimitsMaxAmountAfter, initRateLimitsKeyRateLimitsSlopeAfter = initRateLimits(key, rateLimits_);

    uint256 initRateLimitsOtherKeyOtherRlMaxAmountAfter;
    uint256 initRateLimitsOtherKeyOtherRlSlopeAfter;
    initRateLimitsOtherKeyOtherRlMaxAmountAfter, initRateLimitsOtherKeyOtherRlSlopeAfter = initRateLimits(otherKey, otherRl);

    assert initRateLimitsKeyRateLimitsMaxAmountAfter == maxAmount;
    assert initRateLimitsKeyRateLimitsSlopeAfter == slope;
    assert initRateLimitsOtherKeyOtherRlMaxAmountAfter == initRateLimitsOtherKeyOtherRlMaxAmountBefore;
    assert initRateLimitsOtherKeyOtherRlSlopeAfter == initRateLimitsOtherKeyOtherRlSlopeBefore;
}

rule addInitRateLimits_revert(bytes32 key, address rateLimits_, uint256 maxAmount, uint256 slope) {
    env e;

    uint256 wardsSender                   = wards(e.msg.sender);
    bytes32 userRolesSender               = userRoles(e.msg.sender);
    bytes32 actionsRolesAddInitRateLimits = actionsRoles(to_bytes4(sig:addInitRateLimits(bytes32, address, uint256, uint256).selector));

    addInitRateLimits@withrevert(e, key, rateLimits_, maxAmount, slope);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesAddInitRateLimits == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: delInitRateLimits ---

rule delInitRateLimits(bytes32 key, address rateLimits_) {
    env e;

    bytes32 otherKey;
    address otherRl;
    require otherKey != key || otherRl != rateLimits_;

    uint256 initRateLimitsOtherKeyOtherRlMaxAmountBefore;
    uint256 initRateLimitsOtherKeyOtherRlSlopeBefore;
    initRateLimitsOtherKeyOtherRlMaxAmountBefore, initRateLimitsOtherKeyOtherRlSlopeBefore = initRateLimits(otherKey, otherRl);

    delInitRateLimits(e, key, rateLimits_);

    uint256 initRateLimitsKeyRateLimitsMaxAmountAfter;
    uint256 initRateLimitsKeyRateLimitsSlopeAfter;
    initRateLimitsKeyRateLimitsMaxAmountAfter, initRateLimitsKeyRateLimitsSlopeAfter = initRateLimits(key, rateLimits_);

    uint256 initRateLimitsOtherKeyOtherRlMaxAmountAfter;
    uint256 initRateLimitsOtherKeyOtherRlSlopeAfter;
    initRateLimitsOtherKeyOtherRlMaxAmountAfter, initRateLimitsOtherKeyOtherRlSlopeAfter = initRateLimits(otherKey, otherRl);

    assert initRateLimitsKeyRateLimitsMaxAmountAfter == 0;
    assert initRateLimitsKeyRateLimitsSlopeAfter == 0;
    assert initRateLimitsOtherKeyOtherRlMaxAmountAfter == initRateLimitsOtherKeyOtherRlMaxAmountBefore;
    assert initRateLimitsOtherKeyOtherRlSlopeAfter == initRateLimitsOtherKeyOtherRlSlopeBefore;
}

rule delInitRateLimits_revert(bytes32 key, address rateLimits_) {
    env e;

    uint256 wardsSender                   = wards(e.msg.sender);
    bytes32 userRolesSender               = userRoles(e.msg.sender);
    bytes32 actionsRolesDelInitRateLimits = actionsRoles(to_bytes4(sig:delInitRateLimits(bytes32, address).selector));

    delInitRateLimits@withrevert(e, key, rateLimits_);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesDelInitRateLimits == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: addInitControllerActions ---

rule addInitControllerActions(bytes data, address controller) {
    env e;

    bytes32 otherKey;
    address otherController;
    bytes32 key = keccak256(data);
    require otherKey != key || otherController != controller;

    uint256 initControllerActionsOtherKeyOtherControllerBefore = initControllerActions(otherKey, otherController);

    addInitControllerActions(e, data, controller);

    uint256 initControllerActionsKeyControllerAfter            = initControllerActions(key, controller);
    uint256 initControllerActionsOtherKeyOtherControllerAfter  = initControllerActions(otherKey, otherController);

    assert initControllerActionsKeyControllerAfter == 1;
    assert initControllerActionsOtherKeyOtherControllerAfter == initControllerActionsOtherKeyOtherControllerBefore;
}

rule addInitControllerActions_revert(bytes data, address controller) {
    env e;

    uint256 wardsSender                          = wards(e.msg.sender);
    bytes32 userRolesSender                      = userRoles(e.msg.sender);
    bytes32 actionsRolesAddInitControllerActions = actionsRoles(to_bytes4(sig:addInitControllerActions(bytes, address).selector));

    addInitControllerActions@withrevert(e, data, controller);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesAddInitControllerActions == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}

// --- RoleAuth functions: delInitControllerActions ---

rule delInitControllerActions(bytes32 key, address controller) {
    env e;

    bytes32 otherKey;
    address otherController;
    require otherKey != key || otherController != controller;

    uint256 initControllerActionsOtherKeyOtherControllerBefore = initControllerActions(otherKey, otherController);

    delInitControllerActions(e, key, controller);

    uint256 initControllerActionsKeyControllerAfter            = initControllerActions(key, controller);
    uint256 initControllerActionsOtherKeyOtherControllerAfter  = initControllerActions(otherKey, otherController);

    assert initControllerActionsKeyControllerAfter == 0;
    assert initControllerActionsOtherKeyOtherControllerAfter == initControllerActionsOtherKeyOtherControllerBefore;
}

rule delInitControllerActions_revert(bytes32 key, address controller) {
    env e;

    uint256 wardsSender                          = wards(e.msg.sender);
    bytes32 userRolesSender                      = userRoles(e.msg.sender);
    bytes32 actionsRolesDelInitControllerActions = actionsRoles(to_bytes4(sig:delInitControllerActions(bytes32, address).selector));

    delInitControllerActions@withrevert(e, key, controller);

    bool revert1 = e.msg.value > 0;
    bool revert2 = (userRolesSender & actionsRolesDelInitControllerActions == to_bytes32(0)) && wardsSender != 1;

    assert lastReverted <=> revert1 || revert2;
}
