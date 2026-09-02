# PAS - Parallelized Allocation System

PAS is a governance framework for managing rate-limited operations through authorized actors called cBeams. It provides timelocked proposal execution, configurable rate limits, and role-based access control for interacting with external controllers.

## Contracts

### BeamState

Central registry that manages system configuration and access control. Stores which cBeams are authorized to operate on which rate limit contracts and controllers, defines default rate limits and allowed controller actions, and configures parameters like `hop` (minimum time between increases) and `maxChange` (maximum rate of change). Supports role-based permissions with actions split between timelocked and direct access.

### Configurator

The operational interface used by cBeams to modify rate limits and execute controller actions. Enforces that rate limit changes respect the configured ceilings and requires waiting for `hop` between increases. Also gates controller calls through pre-approved action hashes stored in BeamState.

### Timelock

Extended OpenZeppelin TimelockController with pausing support, permissionless execution, and operation tracking for keeper integration. Disables self-calls to prevent proposals from modifying admin settings.

### PASMom

Emergency governance contract that allows authorized parties to trigger circuit breakers. Can call `stop()` on BeamState to halt Configurator operations and `pause()` on Timelock to block scheduling and execution. Callable by the owner or via the Chief's hat through the authority.

## Unlimited rate limits

A rate limit key is treated as unlimited — the Configurator forces any cBeam call to keep it at `(max, 0)` and rejects any attempt to lower it — in either of these cases:

- It is registered in BeamState as `(max, 0)` (via `addInitRateLimits`), or
- It is currently `(max, 0)` in RateLimits and has no BeamState default for that key.

The second case protects keys that are already unlimited (e.g. withdrawal keys kept unlimited for security) even when they were never registered: a cBeam cannot unilateraly reset such a key to `0`. This holds both when first enabling the Configurator on an already-active PAU and when later opting into a facet that adds such a key.

To make an existing unlimited key adjustable by a cBeam (e.g. to bound it), a `roleAuth` caller must register a bounded default for it via `addInitRateLimits` (through a star spell or the Timelock, depending on how the action is routed); the key then follows the normal bounded-limit rules.
Note that the bounded default must be nonzero in at least one field as (0, 0) is indistinguishable from an unregistered key.

**Warning:** unlocking a protected unlimited key (by registering a bounded default) hands control of it to the cBeam — which can then set it to any value down to `0`, immediately. Treat it as a deliberate governance decision: use a **key-rateLimits** specific default (never the general `address(0)` slot, which applies to that key across all RateLimits contracts), and only for keys you intend to make cBeam-adjustable.
