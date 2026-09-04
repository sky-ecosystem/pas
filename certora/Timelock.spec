// Timelock.spec

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
    function getOperationPayload(bytes32, uint256) external returns (bytes) envfree;
    function getOperationPredecessor(bytes32) external returns (bytes32) envfree;
    function getOperationSalt(bytes32) external returns (bytes32) envfree;

    // Inherited from Pausable
    function paused() external returns (bool) envfree;

    // Inherited from TimelockController
    function getMinDelay() external returns (uint256) envfree;
    function getTimestamp(bytes32) external returns (uint256) envfree;
    function hashOperationBatch(address[], uint256[], bytes[], bytes32, bytes32) external returns (bytes32) envfree;
    function isOperationReady(bytes32) external returns (bool);

    // Inherited from AccessControl
    function hasRole(bytes32, address) external returns (bool) envfree;
    function getRoleAdmin(bytes32) external returns (bytes32) envfree;

    // Inherited from ERC721Holder / ERC1155Holder
    function onERC721Received(address, address, uint256, bytes) external returns (bytes4);
    function onERC1155Received(address, address, uint256, uint256, bytes) external returns (bytes4);
    function onERC1155BatchReceived(address, address, uint256[], uint256[], bytes) external returns (bytes4);
    function PAUSER_ROLE() external returns (bytes32) envfree;
    function PROPOSER_ROLE() external returns (bytes32) envfree;
    function CANCELLER_ROLE() external returns (bytes32) envfree;
    function EXECUTOR_ROLE() external returns (bytes32) envfree;
    function DEFAULT_ADMIN_ROLE() external returns (bytes32) envfree;

    // executeBatch forwards to arbitrary targets. Left unresolved they havoc all contract state,
    // which breaks the list bookkeeping assertions (countBefore is read before the calls) and is
    // very expensive to solve. Scoped to executeBatch so that the legitimate `this.updateDelay`
    // self-call in updateDelayImmediately is still executed for real.
    // Assumption: the executed calls succeed and do not re-enter the Timelock.
    unresolved external in Timelock.executeBatch(address[],uint256[],bytes[],bytes32,bytes32) => NONDET;
}

// --- Definitions ---

definition DONE_TIMESTAMP() returns uint256 = 1;

// --- Storage Affected Rule ---

rule storageAffected(method f) filtered {
    f -> !f.isView &&
         f.selector != sig:execute(address,uint256,bytes,bytes32,bytes32).selector
} {
    env e;
    calldataarg args;

    bytes32 anyId;
    bytes32 anyElemId;
    uint256 anyIdx;
    bytes32 anyRole;
    address anyAccount;

    // Element reads panic out of bounds, so the index is pinned inside the array. A separate id is
    // used for them so that this assumption does not also narrow the checks below, which apply to
    // any id. Methods that do not touch _operations leave the length alone, so the post-state read
    // stays in range for them.
    require anyIdx < getOperationLength(anyElemId);

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
    address targetBefore          = getOperationTarget(anyElemId, anyIdx);
    uint256 valueBefore           = getOperationValue(anyElemId, anyIdx);
    bytes   payloadBefore         = getOperationPayload(anyElemId, anyIdx);

    // Pausable state
    bool    pausedBefore          = paused();

    // TimelockController state
    uint256 minDelayBefore        = getMinDelay();
    uint256 timestampBefore       = getTimestamp(anyId);

    // AccessControl state
    bool    hasRoleBefore         = hasRole(anyRole, anyAccount);
    bytes32 roleAdminBefore       = getRoleAdmin(anyRole);

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
    address targetAfter           = getOperationTarget(anyElemId, anyIdx);
    uint256 valueAfter            = getOperationValue(anyElemId, anyIdx);
    bytes   payloadAfter          = getOperationPayload(anyElemId, anyIdx);

    // Pausable state
    bool    pausedAfter           = paused();

    // TimelockController state
    uint256 minDelayAfter         = getMinDelay();
    uint256 timestampAfter        = getTimestamp(anyId);

    // AccessControl state
    bool    hasRoleAfter          = hasRole(anyRole, anyAccount);
    bytes32 roleAdminAfter        = getRoleAdmin(anyRole);

    // Linked list can only be modified by scheduleBatch, cancel, executeBatch
    assert (firstAfter != firstBefore || lastAfter != lastBefore || countAfter != countBefore ||
            existsAfter != existsBefore || prevAfter != prevBefore || nextAfter != nextBefore) =>
        f.selector == sig:scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256).selector ||
        f.selector == sig:cancel(bytes32).selector ||
        f.selector == sig:executeBatch(address[],uint256[],bytes[],bytes32,bytes32).selector;

    // Operation data, including the targets/values/payloads contents, can only be modified by
    // scheduleBatch, cancel, executeBatch
    assert (lengthAfter != lengthBefore || predecessorAfter != predecessorBefore ||
            saltAfter != saltBefore || targetAfter != targetBefore ||
            valueAfter != valueBefore || payloadAfter != payloadBefore) =>
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

    // _timestamps is written by _schedule, deleted by cancel and set to DONE by _afterCall
    assert timestampAfter != timestampBefore =>
        f.selector == sig:scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256).selector ||
        f.selector == sig:cancel(bytes32).selector ||
        f.selector == sig:executeBatch(address[],uint256[],bytes[],bytes32,bytes32).selector;

    // Role membership can only be modified by the AccessControl mutators
    assert hasRoleAfter != hasRoleBefore =>
        f.selector == sig:grantRole(bytes32,address).selector ||
        f.selector == sig:revokeRole(bytes32,address).selector ||
        f.selector == sig:renounceRole(bytes32,address).selector;

    // _setRoleAdmin is internal and never called, so role admins never change after construction
    assert roleAdminAfter == roleAdminBefore;
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
    uint256 idx;

    require !getOperationExists(id);

    scheduleBatch(e, targets, values, payloads, predecessor, salt, delay);

    uint256 countAfter = getOperationsCount();
    bool existsAfter = getOperationExists(id);
    bytes32 lastAfter = getLastOperationId();

    bool targetMatches = true;
    bool valueMatches  = true;
    if (targets.length > 0) {
        require idx < targets.length;
        targetMatches = getOperationTarget(id, idx) == targets[idx];
        valueMatches  = getOperationValue(id, idx) == values[idx];
    }

    assert countAfter == countBefore + 1;
    assert existsAfter;
    assert lastAfter == id;

    // The stored operation mirrors what was scheduled
    assert getOperationLength(id) == targets.length;
    assert getOperationPredecessor(id) == predecessor;
    assert getOperationSalt(id) == salt;
    // _schedule sets _timestamps[id] = block.timestamp + delay
    assert getTimestamp(id) == assert_uint256(e.block.timestamp + delay);
    assert targetMatches;
    assert valueMatches;
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

    bool    existsBefore = getOperationExists(id);
    uint256 countBefore  = getOperationsCount();

    scheduleBatch@withrevert(e, targets, values, payloads, predecessor, salt, delay);

    bool revert1  = e.msg.value > 0;
    bool revert2  = isPaused;
    bool revert3  = exists uint256 i. i < targets.length && targets[i] == currentContract;
    bool revert4  = !isProposer;
    bool revert5  = targets.length != values.length || targets.length != payloads.length;
    bool revert6  = isOp;                  // Operation already scheduled in TimelockController
    bool revert7  = delay < minDelay;
    // Linked list add fails. Note _operationIds.exists and TimelockController's _timestamps are
    // separate storage, so this is not implied by revert5.
    bool revert8  = id == to_bytes32(0) || existsBefore;
    // _schedule writes _timestamps[id] = block.timestamp + delay under checked arithmetic
    bool revert9  = e.block.timestamp + delay > max_uint256;
    // Bytes32LinkedList.add does a checked count++
    bool revert10 = countBefore == max_uint256;
    // A target equal to the timelock also reverts; that case is proven by selfCallPrevention,
    // which covers an arbitrary index without needing a quantifier here.

    // Necessary direction only. The converse is not provable: writing _operations[id] makes
    // Solidity clear and overwrite the previous payloads, and from an unconstrained pre-state the
    // stale storage slots at and past the array length can hold an invalid byte-array encoding,
    // which panics (Panic 0x22). That is unreachable in practice -- only the contract ever writes
    // those slots -- but it is also not expressible as a CVL assumption, because constraining
    // `payloads.length` says nothing about the element slots beyond the length. This is the same
    // wall that keeps cancel_revert_length_0 restricted to the empty-payloads case.
    assert revert1 || revert2 || revert3 ||
           revert4 || revert5 || revert6 ||
           revert7 || revert8 || revert9 ||
           revert10 => lastReverted;
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
    // cancel deletes _timestamps[id]
    assert getTimestamp(id) == 0;
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
    // _afterCall marks the operation done rather than clearing it
    assert getTimestamp(id) == DONE_TIMESTAMP();
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

    // Execution is permissionless only while EXECUTOR_ROLE is held by address(0), which the
    // constructor grants but which cannot be assumed from an arbitrary pre-state
    bool isOpenExecutor = hasRole(EXECUTOR_ROLE(), 0);
    bool isExecutor     = hasRole(EXECUTOR_ROLE(), e.msg.sender);

    bool    existsBefore = getOperationExists(id);
    uint256 countBefore  = getOperationsCount();

    executeBatch@withrevert(e, targets, values, payloads, predecessor, salt);

    bool revert1 = isPaused;                        // whenNotPaused on the override
    bool revert2 = !isOpenExecutor && !isExecutor;  // onlyRoleOrOpenRole(EXECUTOR_ROLE)
    bool revert3 = targets.length != values.length ||
                   targets.length != payloads.length;   // TimelockInvalidOperationLength
    bool revert4 = !isReady;                        // _beforeCall, re-checked by _afterCall
    bool revert5 = !predecessorDone;                // _beforeCall
    bool revert6 = !existsBefore;                   // require(_operationIds.remove(id))
    bool revert7 = countBefore == 0;                // checked count-- inside remove

    // Necessary direction only. Two causes are not stated: `delete _operations[id]` clears the
    // stored payloads, and stale slots from an unconstrained pre-state can hold an invalid
    // byte-array encoding that panics (Panic 0x22) -- unreachable in practice but not expressible
    // as a CVL assumption; and forwarding values[i] fails once the running balance is short, whose
    // exact condition is a prefix sum over a symbolic-length calldata array. Both would have to be
    // assumed away to reach `<=>`, which is not worth narrowing this rule for.
    // The target calls themselves are summarized NONDET, so "external call fails" is not a cause.
    assert revert1 || revert2 || revert3 || revert4 ||
           revert5 || revert6 || revert7 => lastReverted;
}

// --- Access control mutators ---

rule grantRole(bytes32 role, address account) {
    env e;

    bytes32 otherRole;
    address otherAccount;
    require otherRole != role || otherAccount != account;

    bool otherBefore = hasRole(otherRole, otherAccount);

    grantRole(e, role, account);

    assert hasRole(role, account);
    assert hasRole(otherRole, otherAccount) == otherBefore;
}

rule grantRole_revert(bytes32 role, address account) {
    env e;

    bool isRoleAdmin = hasRole(getRoleAdmin(role), e.msg.sender);

    grantRole@withrevert(e, role, account);

    bool revert1 = e.msg.value > 0;
    bool revert2 = !isRoleAdmin;

    assert lastReverted <=> revert1 || revert2;
}

rule revokeRole(bytes32 role, address account) {
    env e;

    bytes32 otherRole;
    address otherAccount;
    require otherRole != role || otherAccount != account;

    bool otherBefore = hasRole(otherRole, otherAccount);

    revokeRole(e, role, account);

    assert !hasRole(role, account);
    assert hasRole(otherRole, otherAccount) == otherBefore;
}

rule revokeRole_revert(bytes32 role, address account) {
    env e;

    bool isRoleAdmin = hasRole(getRoleAdmin(role), e.msg.sender);

    revokeRole@withrevert(e, role, account);

    bool revert1 = e.msg.value > 0;
    bool revert2 = !isRoleAdmin;

    assert lastReverted <=> revert1 || revert2;
}

// Renouncing takes no role admin: any account may drop its own role, and only its own
rule renounceRole(bytes32 role, address callerConfirmation) {
    env e;

    bytes32 otherRole;
    address otherAccount;
    require otherRole != role || otherAccount != callerConfirmation;

    bool otherBefore = hasRole(otherRole, otherAccount);

    renounceRole(e, role, callerConfirmation);

    assert !hasRole(role, callerConfirmation);
    assert hasRole(otherRole, otherAccount) == otherBefore;
}

rule renounceRole_revert(bytes32 role, address callerConfirmation) {
    env e;

    renounceRole@withrevert(e, role, callerConfirmation);

    bool revert1 = e.msg.value > 0;
    bool revert2 = callerConfirmation != e.msg.sender;   // AccessControlBadConfirmation

    assert lastReverted <=> revert1 || revert2;
}

// --- Inherited updateDelay ---

// The inherited updateDelay is callable only by the timelock itself, which is what stops a
// proposal from rewriting the min delay; updateDelayImmediately reaches it via an external
// self-call after checking DEFAULT_ADMIN_ROLE
rule updateDelay(uint256 newDelay) {
    env e;

    require e.msg.sender == currentContract;

    updateDelay(e, newDelay);

    assert getMinDelay() == newDelay;
}

rule updateDelay_revert(uint256 newDelay) {
    env e;

    updateDelay@withrevert(e, newDelay);

    bool revert1 = e.msg.value > 0;
    bool revert2 = e.msg.sender != currentContract;   // TimelockUnauthorizedCaller

    assert lastReverted <=> revert1 || revert2;
}

// --- Token receiver hooks ---

// The holder hooks accept transfers unconditionally and touch no storage; storageAffected already
// covers the absence of side effects, these pin the returned magic values
rule onERC721Received_returns_selector(address operator, address from, uint256 tokenId, bytes data) {
    env e;

    bytes4 ret = onERC721Received(e, operator, from, tokenId, data);

    assert ret == to_bytes4(sig:onERC721Received(address,address,uint256,bytes).selector);
}

rule onERC721Received_revert(address operator, address from, uint256 tokenId, bytes data) {
    env e;

    onERC721Received@withrevert(e, operator, from, tokenId, data);

    assert lastReverted <=> e.msg.value > 0;
}

rule onERC1155Received_returns_selector(address operator, address from, uint256 id, uint256 value, bytes data) {
    env e;

    bytes4 ret = onERC1155Received(e, operator, from, id, value, data);

    assert ret == to_bytes4(sig:onERC1155Received(address,address,uint256,uint256,bytes).selector);
}

rule onERC1155Received_revert(address operator, address from, uint256 id, uint256 value, bytes data) {
    env e;

    onERC1155Received@withrevert(e, operator, from, id, value, data);

    assert lastReverted <=> e.msg.value > 0;
}

rule onERC1155BatchReceived_returns_selector(address operator, address from, uint256[] ids, uint256[] values, bytes data) {
    env e;

    bytes4 ret = onERC1155BatchReceived(e, operator, from, ids, values, data);

    assert ret == to_bytes4(sig:onERC1155BatchReceived(address,address,uint256[],uint256[],bytes).selector);
}

rule onERC1155BatchReceived_revert(address operator, address from, uint256[] ids, uint256[] values, bytes data) {
    env e;

    onERC1155BatchReceived@withrevert(e, operator, from, ids, values, data);

    assert lastReverted <=> e.msg.value > 0;
}
