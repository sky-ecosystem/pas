// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Timelock.spec -- Formal verification spec for Timelock

using Timelock as timelock;

// --- Methods block ---

methods {
    // Timelock linked list getters
    function getFirstOperationId() external returns (bytes32) envfree;
    function getLastOperationId() external returns (bytes32) envfree;
    function getOperationsCount() external returns (uint256) envfree;
    function getPrevOperationId(bytes32) external returns (bytes32) envfree;
    function getNextOperationId(bytes32) external returns (bytes32) envfree;
    function getOperationExists(bytes32) external returns (bool) envfree;

    // Timelock operation data getters
    function getOperationLength(bytes32) external returns (uint256) envfree;
    function getOperationTarget(bytes32, uint256) external returns (address) envfree;
    function getOperationValue(bytes32, uint256) external returns (uint256) envfree;
    function getOperationPredecessor(bytes32) external returns (bytes32) envfree;
    function getOperationSalt(bytes32) external returns (bytes32) envfree;

    // Inherited from Pausable
    function paused() external returns (bool) envfree;

    // Inherited from TimelockController
    function getMinDelay() external returns (uint256) envfree;
    function getTimestamp(bytes32) external returns (uint256) envfree;
    function hashOperationBatch(address[], uint256[], bytes[], bytes32, bytes32) external returns (bytes32) envfree;
    function isOperationReady(bytes32, uint256) external returns (bool);

    // Inherited from AccessControl
    function hasRole(bytes32, address) external returns (bool) envfree;
    function PAUSER_ROLE() external returns (bytes32) envfree;
    function PROPOSER_ROLE() external returns (bytes32) envfree;
    function CANCELLER_ROLE() external returns (bytes32) envfree;
    function EXECUTOR_ROLE() external returns (bytes32) envfree;
    function DEFAULT_ADMIN_ROLE() external returns (bytes32) envfree;

    // // External call summaries - treat external calls as non-deterministic
    // function _._ external => NONDET;
}

// --- Definitions ---

definition DONE_TIMESTAMP() returns uint256 = 1;

// --- Storage Affected Rule ---

rule storageAffected(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;

    bytes32 anyId;

    // Linked list state
    bytes32 firstBefore           = getFirstOperationId();
    bytes32 lastBefore            = getLastOperationId();
    uint256 countBefore           = getOperationsCount();
    bytes32 prevBefore            = getPrevOperationId(anyId);
    bytes32 nextBefore            = getNextOperationId(anyId);
    bool    existsBefore          = getOperationExists(anyId);

    // Operation data
    uint256 lengthBefore          = getOperationLength(anyId);
    bytes32 predecessorBefore     = getOperationPredecessor(anyId);
    bytes32 saltBefore            = getOperationSalt(anyId);

    // Pausable state
    bool    pausedBefore          = paused();

    // TimelockController state
    uint256 minDelayBefore        = getMinDelay();

    f(e, args);

    // Linked list state
    bytes32 firstAfter            = getFirstOperationId();
    bytes32 lastAfter             = getLastOperationId();
    uint256 countAfter            = getOperationsCount();
    bytes32 prevAfter             = getPrevOperationId(anyId);
    bytes32 nextAfter             = getNextOperationId(anyId);
    bool    existsAfter           = getOperationExists(anyId);

    // Operation data
    uint256 lengthAfter           = getOperationLength(anyId);
    bytes32 predecessorAfter      = getOperationPredecessor(anyId);
    bytes32 saltAfter             = getOperationSalt(anyId);

    // Pausable state
    bool    pausedAfter           = paused();

    // TimelockController state
    uint256 minDelayAfter         = getMinDelay();

    // Linked list can only be modified by scheduleBatch, cancel, executeBatch
    assert (firstAfter != firstBefore || lastAfter != lastBefore || countAfter != countBefore ||
            existsAfter != existsBefore || prevAfter != prevBefore || nextAfter != nextBefore) =>
        f.selector == sig:scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256).selector ||
        f.selector == sig:cancel(bytes32).selector ||
        f.selector == sig:executeBatch(address[],uint256[],bytes[],bytes32,bytes32).selector;

    // Operation data can only be modified by scheduleBatch, cancel, executeBatch
    assert (lengthAfter != lengthBefore || predecessorAfter != predecessorBefore || saltAfter != saltBefore) =>
        f.selector == sig:scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256).selector ||
        f.selector == sig:cancel(bytes32).selector ||
        f.selector == sig:executeBatch(address[],uint256[],bytes[],bytes32,bytes32).selector;

    // paused can only be modified by pause, unpause
    assert pausedAfter != pausedBefore =>
        f.selector == sig:pause().selector ||
        f.selector == sig:unpause().selector;

    // minDelay can only be modified by updateDelayImmediately (and inherited updateDelay, but it requires self-call)
    assert minDelayAfter != minDelayBefore =>
        f.selector == sig:updateDelay(uint256).selector ||
        f.selector == sig:updateDelayImmediately(uint256).selector;
}

// --- Pausing rules ---

rule pause() {
    env e;

    pause(e);

    assert paused() == true;
}

rule pause_revert() {
    env e;

    bool isPauser = hasRole(PAUSER_ROLE(), e.msg.sender);
    bool isPausedBefore = paused();

    pause@withrevert(e);

    bool revert1 = e.msg.value > 0;
    bool revert2 = !isPauser;
    bool revert3 = isPausedBefore;

    assert lastReverted <=> revert1 || revert2 || revert3;
}

rule unpause() {
    env e;

    unpause(e);

    assert paused() == false;
}

rule unpause_revert() {
    env e;

    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);
    bool isPausedBefore = paused();

    unpause@withrevert(e);

    bool revert1 = e.msg.value > 0;
    bool revert2 = !isAdmin;
    bool revert3 = !isPausedBefore;

    assert lastReverted <=> revert1 || revert2 || revert3;
}

// --- Schedule rules ---

rule schedule_always_reverts(address target, uint256 value, bytes payload, bytes32 predecessor, bytes32 salt, uint256 delay) {
    env e;

    schedule@withrevert(e, target, value, payload, predecessor, salt, delay);

    assert lastReverted;
}

rule scheduleBatch_adds_to_list(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
) {
    env e;

    uint256 countBefore = getOperationsCount();
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);

    require !getOperationExists(id);

    scheduleBatch(e, targets, values, payloads, predecessor, salt, delay);

    uint256 countAfter = getOperationsCount();
    bool existsAfter = getOperationExists(id);
    bytes32 lastAfter = getLastOperationId();

    assert countAfter == countBefore + 1;
    assert existsAfter == true;
    assert lastAfter == id;
}

rule scheduleBatch_no_side_effects(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
) {
    env e;

    bytes32 otherId;
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
    require otherId != id;

    bool otherExistsBefore = getOperationExists(otherId);
    bytes32 otherPrevBefore = getPrevOperationId(otherId);
    uint256 otherLengthBefore = getOperationLength(otherId);
    bytes32 otherPredecessorBefore = getOperationPredecessor(otherId);
    bytes32 otherSaltBefore = getOperationSalt(otherId);

    scheduleBatch(e, targets, values, payloads, predecessor, salt, delay);

    bool otherExistsAfter = getOperationExists(otherId);
    bytes32 otherPrevAfter = getPrevOperationId(otherId);
    uint256 otherLengthAfter = getOperationLength(otherId);
    bytes32 otherPredecessorAfter = getOperationPredecessor(otherId);
    bytes32 otherSaltAfter = getOperationSalt(otherId);

    // Note: next pointer of the previous last element will change if otherId was the last element
    assert otherExistsAfter == otherExistsBefore;
    assert otherPrevAfter == otherPrevBefore;
    assert otherLengthAfter == otherLengthBefore;
    assert otherPredecessorAfter == otherPredecessorBefore;
    assert otherSaltAfter == otherSaltBefore;
}

rule scheduleBatch_revert(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
) {
    env e;

    bool isPaused = paused();
    bool isProposer = hasRole(PROPOSER_ROLE(), e.msg.sender);
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
    bool isOp = isOperation(e, id);
    uint256 minDelay = getMinDelay();

    // Check array lengths match
    require targets.length == values.length;
    require targets.length == payloads.length;

    scheduleBatch@withrevert(e, targets, values, payloads, predecessor, salt, delay);

    bool revert1 = e.msg.value > 0;
    bool revert2 = isPaused;
    bool revert3 = !isProposer;
    bool revert4 = isOp; // Operation already exists in TimelockController
    bool revert5 = delay < minDelay;
    // revert6: self-call check - one of targets == address(this)
    // revert7: linked list add fails (id == 0 or already exists) - covered by revert4

    assert revert1 || revert2 || revert3 || revert4 || revert5 => lastReverted;
}

// --- Cancel rules ---

rule cancel_removes_from_list(bytes32 id) {
    env e;

    uint256 countBefore = getOperationsCount();

    require getOperationExists(id);

    cancel(e, id);

    uint256 countAfter = getOperationsCount();
    bool existsAfter = getOperationExists(id);
    uint256 lengthAfter = getOperationLength(id);

    assert countAfter == countBefore - 1;
    assert existsAfter == false;
    assert lengthAfter == 0;
}

rule cancel_no_side_effects(bytes32 id) {
    env e;

    bytes32 otherId;
    require otherId != id;

    bool otherExistsBefore = getOperationExists(otherId);
    uint256 otherLengthBefore = getOperationLength(otherId);
    bytes32 otherPredecessorBefore = getOperationPredecessor(otherId);
    bytes32 otherSaltBefore = getOperationSalt(otherId);

    cancel(e, id);

    bool otherExistsAfter = getOperationExists(otherId);
    uint256 otherLengthAfter = getOperationLength(otherId);
    bytes32 otherPredecessorAfter = getOperationPredecessor(otherId);
    bytes32 otherSaltAfter = getOperationSalt(otherId);

    // Note: prev/next pointers of adjacent nodes may change
    assert otherExistsAfter == otherExistsBefore;
    assert otherLengthAfter == otherLengthBefore;
    assert otherPredecessorAfter == otherPredecessorBefore;
    assert otherSaltAfter == otherSaltBefore;
}

rule cancel_revert(bytes32 id) {
    env e;

    bool isPaused = paused();
    bool isCanceller = hasRole(CANCELLER_ROLE(), e.msg.sender);
    bool isPending = isOperationPending(e, id);
    bool opExists = getOperationExists(id);

    cancel@withrevert(e, id);

    bool revert1 = e.msg.value > 0;
    bool revert2 = isPaused;
    bool revert3 = !isCanceller;
    bool revert4 = !isPending;
    bool revert5 = !opExists;

    assert revert1 || revert2 || revert3 || revert4 || revert5 => lastReverted;
}

rule cancel_revert_length_0(bytes32 id) {
    env e;

    bool isPaused = paused();
    bool isCanceller = hasRole(CANCELLER_ROLE(), e.msg.sender);
    bool isPending = isOperationPending(e, id);
    bool opExists = getOperationExists(id);

    require getOperationsCount() > 0;

    require currentContract._operations[id].payloads.length == 0;

    cancel@withrevert(e, id);

    bool revert1 = e.msg.value > 0;
    bool revert2 = isPaused;
    bool revert3 = !isCanceller;
    bool revert4 = !isPending;
    bool revert5 = !opExists;

    assert lastReverted <=> revert1 || revert2 || revert3 || revert4 || revert5;
}

// --- Execute rules ---

rule execute_always_reverts(address target, uint256 value, bytes payload, bytes32 predecessor, bytes32 salt) {
    env e;

    execute@withrevert(e, target, value, payload, predecessor, salt);

    assert lastReverted;
}

rule executeBatch_removes_from_list(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt
) {
    env e;

    uint256 countBefore = getOperationsCount();
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);

    require getOperationExists(id);

    executeBatch(e, targets, values, payloads, predecessor, salt);

    uint256 countAfter = getOperationsCount();
    bool existsAfter = getOperationExists(id);
    uint256 lengthAfter = getOperationLength(id);

    assert countAfter == countBefore - 1;
    assert existsAfter == false;
    assert lengthAfter == 0;
}

rule executeBatch_revert(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt
) {
    env e;

    bool isPaused = paused();
    bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
    bool isReady = isOperationReady(e, id);
    bool predecessorDone = predecessor == to_bytes32(0) || isOperationDone(e, predecessor);

    // Check array lengths match
    require targets.length == values.length;
    require targets.length == payloads.length;

    executeBatch@withrevert(e, targets, values, payloads, predecessor, salt);

    bool revert1 = e.msg.value > 0 && e.msg.value != values[0]; // Only fails if value mismatch
    bool revert2 = isPaused;
    bool revert3 = !isReady;
    bool revert4 = !predecessorDone;
    // revert5: external call fails
    // revert6: linked list remove fails (doesn't exist)

    assert revert2 || revert3 || revert4 => lastReverted;
}

// --- Delay management rules ---

rule updateDelayImmediately(uint256 newDelay) {
    env e;

    updateDelayImmediately(e, newDelay);

    uint256 minDelayAfter = getMinDelay();

    assert minDelayAfter == newDelay;
}

rule updateDelayImmediately_revert(uint256 newDelay) {
    env e;

    bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    updateDelayImmediately@withrevert(e, newDelay);

    bool revert1 = e.msg.value > 0;
    bool revert2 = !isAdmin;

    assert lastReverted <=> revert1 || revert2;
}

// --- Linked list invariants ---

invariant emptyListConsistency()
    getOperationsCount() == 0 <=> (getFirstOperationId() == to_bytes32(0) && getLastOperationId() == to_bytes32(0))
    {
        preserved scheduleBatch(address[] targets, uint256[] values, bytes[] payloads, bytes32 predecessor, bytes32 salt, uint256 delay) with (env e) {
            // Hash cannot be zero for valid operations
            require hashOperationBatch(targets, values, payloads, predecessor, salt) != to_bytes32(0);
        }
    }

// // --- Linked list structure invariants ---

// // First element has no predecessor
// invariant firstHasNoPrev()
//     getFirstOperationId() != to_bytes32(0) => getPrevOperationId(getFirstOperationId()) == to_bytes32(0)
//     {
//         preserved scheduleBatch(address[] targets, uint256[] values, bytes[] payloads, bytes32 predecessor, bytes32 salt, uint256 delay) with (env e) {
//             require hashOperationBatch(targets, values, payloads, predecessor, salt) != to_bytes32(0);
//         }
//     }

// // Last element has no successor
// invariant lastHasNoNext()
//     getLastOperationId() != to_bytes32(0) => getNextOperationId(getLastOperationId()) == to_bytes32(0)
//     {
//         preserved scheduleBatch(address[] targets, uint256[] values, bytes[] payloads, bytes32 predecessor, bytes32 salt, uint256 delay) with (env e) {
//             require hashOperationBatch(targets, values, payloads, predecessor, salt) != to_bytes32(0);
//         }
//     }

// // If an operation exists, count must be positive
// invariant existsImpliesPositiveCount(bytes32 id)
//     getOperationExists(id) => getOperationsCount() > 0
//     {
//         preserved scheduleBatch(address[] targets, uint256[] values, bytes[] payloads, bytes32 predecessor, bytes32 salt, uint256 delay) with (env e) {
//             require hashOperationBatch(targets, values, payloads, predecessor, salt) != to_bytes32(0);
//         }
//     }

// // If operation exists in linked list, it has data (at least one target)
// invariant operationExistsImpliesData(bytes32 id)
//     getOperationExists(id) => getOperationLength(id) > 0
//     {
//         preserved scheduleBatch(address[] targets, uint256[] values, bytes[] payloads, bytes32 predecessor, bytes32 salt, uint256 delay) with (env e) {
//             require hashOperationBatch(targets, values, payloads, predecessor, salt) != to_bytes32(0);
//             require targets.length > 0;
//         }
//     }

// --- Access control rules ---

rule onlyPauserCanPause() {
    env e;

    require !hasRole(PAUSER_ROLE(), e.msg.sender);

    pause@withrevert(e);

    assert lastReverted;
}

rule onlyAdminCanUnpause() {
    env e;

    require !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    unpause@withrevert(e);

    assert lastReverted;
}

rule onlyAdminCanUpdateDelay() {
    env e;
    uint256 newDelay;

    require !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender);

    updateDelayImmediately@withrevert(e, newDelay);

    assert lastReverted;
}

rule onlyProposerCanSchedule(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
) {
    env e;

    require !hasRole(PROPOSER_ROLE(), e.msg.sender);

    scheduleBatch@withrevert(e, targets, values, payloads, predecessor, salt, delay);

    assert lastReverted;
}

rule onlyCancellerCanCancel(bytes32 id) {
    env e;

    require !hasRole(CANCELLER_ROLE(), e.msg.sender);

    cancel@withrevert(e, id);

    assert lastReverted;
}

// --- Paused state rules ---

rule whenPausedScheduleReverts(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
) {
    env e;

    require paused();

    scheduleBatch@withrevert(e, targets, values, payloads, predecessor, salt, delay);

    assert lastReverted;
}

rule whenPausedCancelReverts(bytes32 id) {
    env e;

    require paused();

    cancel@withrevert(e, id);

    assert lastReverted;
}

rule whenPausedExecuteReverts(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt
) {
    env e;

    require paused();

    executeBatch@withrevert(e, targets, values, payloads, predecessor, salt);

    assert lastReverted;
}

// --- Self-call prevention ---

// This rule verifies that scheduleBatch reverts when any target is the timelock itself
// Note: This is a property check that should be verified
rule selfCallPrevention(
    address[] targets,
    uint256[] values,
    bytes[] payloads,
    bytes32 predecessor,
    bytes32 salt,
    uint256 delay
) {
    env e;

    // Assume first target is the contract itself
    require targets.length > 0;
    require targets[0] == currentContract;

    scheduleBatch@withrevert(e, targets, values, payloads, predecessor, salt, delay);

    assert lastReverted;
}
