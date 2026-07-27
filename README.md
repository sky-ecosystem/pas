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

Any rate limit meant to stay unlimited must be registered in BeamState as `(max, 0)` (via `addInitRateLimits`). Otherwise the Configurator treats it as a normal bounded limit that a cBeam can lower. This applies both when first enabling the Configurator on an already-active PAU (every existing key meant to be unlimited must be registered) and when later opting into a facet that adds such a key. In both cases stars are expected to make sure to register it as `(max, 0)` (via a core spell or the Timelock, depending on whether it is coordinated through a star spell or the Timelock).
