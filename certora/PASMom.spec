// PASMom.spec

using BeamState as beamState;
using Timelock as timelock;

// --- Methods block ---

methods {
    // PASMom storage getters
    function owner()     external returns (address) envfree;
    function authority() external returns (address) envfree;

    // PASMom immutable getters
    function beamState() external returns (address) envfree;
    function timelock()  external returns (address) envfree;

    // BeamState functions reached through PASMom.stop
    function beamState.stopped()            external returns (bool)    envfree;
    function beamState.wards(address)       external returns (uint256) envfree;
    function beamState.userRoles(address)   external returns (bytes32) envfree;
    function beamState.actionsRoles(bytes4) external returns (bytes32) envfree;

    // Timelock functions reached through PASMom.pause
    function timelock.paused()                  external returns (bool)    envfree;
    function timelock.hasRole(bytes32, address) external returns (bool)    envfree;
    function timelock.PAUSER_ROLE()             external returns (bytes32) envfree;

    // The authority is not part of the scene, its answer is modelled by a ghost so that
    // both the `authority == 0` and the `authority != 0` branches stay reachable
    function _.canCall(address src, address dst, bytes4 sig_) external => canCallGhost(src, dst, sig_) expect bool;
}

ghost canCallGhost(address, address, bytes4) returns bool;

// --- Storage Affected Rule ---

rule storageAffected(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;

    address ownerBefore     = owner();
    address authorityBefore = authority();

    f(e, args);

    address ownerAfter     = owner();
    address authorityAfter = authority();

    assert ownerAfter != ownerBefore =>
        f.selector == sig:setOwner(address).selector;
    assert authorityAfter != authorityBefore =>
        f.selector == sig:setAuthority(address).selector;
}

// --- Admin functions: setOwner ---

rule setOwner(address owner_) {
    env e;

    setOwner(e, owner_);

    assert owner() == owner_;
}

rule setOwner_revert(address owner_) {
    env e;

    address ownerBefore = owner();

    setOwner@withrevert(e, owner_);

    bool revert1 = e.msg.value > 0;
    bool revert2 = e.msg.sender != ownerBefore;

    assert lastReverted <=> revert1 || revert2;
}

// --- Admin functions: setAuthority ---

rule setAuthority(address authority_) {
    env e;

    setAuthority(e, authority_);

    assert authority() == authority_;
}

rule setAuthority_revert(address authority_) {
    env e;

    address ownerBefore = owner();

    setAuthority@withrevert(e, authority_);

    bool revert1 = e.msg.value > 0;
    bool revert2 = e.msg.sender != ownerBefore;

    assert lastReverted <=> revert1 || revert2;
}

// --- Emergency functions: stop ---

rule stop() {
    env e;

    stop(e);

    assert beamState.stopped() == true;
}

rule stop_revert() {
    env e;

    address ownerBefore     = owner();
    address authorityBefore = authority();
    bool    canCall         = canCallGhost(e.msg.sender, currentContract, to_bytes4(sig:stop().selector));

    // BeamState.stop() is roleAuth'd on PASMom as the caller.
    // Note: PASMom.stop() and BeamState.stop() share the same `stop()` selector.
    uint256 beamStateWards        = beamState.wards(currentContract);
    bytes32 beamStateUserRoles    = beamState.userRoles(currentContract);
    bytes32 beamStateActionsRoles = beamState.actionsRoles(to_bytes4(sig:stop().selector));

    stop@withrevert(e);

    bool revert1 = e.msg.value > 0;
    // isAuthorized: the owner always passes, anyone else needs a non-zero authority that allows it
    bool revert2 = e.msg.sender != ownerBefore && (authorityBefore == 0 || !canCall);
    // BeamState.roleAuth, with PASMom as the caller
    bool revert3 = (beamStateUserRoles & beamStateActionsRoles == to_bytes32(0)) && beamStateWards != 1;

    assert lastReverted <=> revert1 || revert2 || revert3;
}

// --- Emergency functions: pause ---

rule pause() {
    env e;

    pause(e);

    assert timelock.paused() == true;
}

rule pause_revert() {
    env e;

    address ownerBefore     = owner();
    address authorityBefore = authority();
    bool    canCall         = canCallGhost(e.msg.sender, currentContract, to_bytes4(sig:pause().selector));

    // Timelock.pause() requires PAUSER_ROLE on PASMom and is blocked while already paused.
    // Note: PASMom.pause() and Timelock.pause() share the same `pause()` selector.
    bool timelockIsPauser = timelock.hasRole(timelock.PAUSER_ROLE(), currentContract);
    bool timelockIsPaused = timelock.paused();

    pause@withrevert(e);

    bool revert1 = e.msg.value > 0;
    // isAuthorized: the owner always passes, anyone else needs a non-zero authority that allows it
    bool revert2 = e.msg.sender != ownerBefore && (authorityBefore == 0 || !canCall);
    bool revert3 = !timelockIsPauser;
    bool revert4 = timelockIsPaused;

    assert lastReverted <=> revert1 || revert2 || revert3 || revert4;
}
