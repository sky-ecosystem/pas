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

### L2PASDeployer

One-time deployer that deploys and initializes a full PAS instance (BeamState, Configurator and Timelock) in its constructor.

## Unlimited rate limits

A rate limit key is treated as unlimited — the Configurator forces any cBeam call to keep it at `(max, 0)` and rejects any attempt to lower it — in either of these cases:

- It is registered in BeamState as `(max, 0)` (via `addInitRateLimits`), or
- It is currently `(max, 0)` in RateLimits and has no BeamState default for that key.

The second case protects keys that are already unlimited (e.g. withdrawal keys kept unlimited for security) even when they were never registered: a cBeam cannot unilateraly reset such a key to `0`. This holds both when first enabling the Configurator on an already-active PAU and when later opting into a facet that adds such a key.

To make an existing unlimited key adjustable by a cBeam (e.g. to bound it), a `roleAuth` caller must register a bounded default for it via `addInitRateLimits` (through a star spell or the Timelock, depending on how the action is routed); the key then follows the normal bounded-limit rules.
Note that the bounded default must be nonzero in at least one field as (0, 0) is indistinguishable from an unregistered key.

**Warning:** unlocking a protected unlimited key (by registering a bounded default) hands control of it to the cBeam — which can then set it to any value down to `0`, immediately. Treat it as a deliberate governance decision: use a **key-rateLimits** specific default (never the general `address(0)` slot, which applies to that key across all RateLimits contracts), and only for keys you intend to make cBeam-adjustable.

## Audits

Audit reports are hosted on the auditors' public portfolio pages:

| Auditor | Report | Date |
| --- | --- | --- |
| Cantina | [Sky: L2 PAS Deployer](https://cantina.xyz/portfolio/57f9de44-9e9a-4471-a554-862ffa46869a) | 2026-10-01 |
| Cantina | [Sky: PAS configurator-unit](https://cantina.xyz/portfolio/da5a4070-7ee8-4cd4-a5dd-cf29ca73df21) | 2026-08-10 |
| ChainSecurity | [Sky Parallelized Allocation System (PAS)](https://www.chainsecurity.com/security-audit/sky-parallelized-allocation-system/) | 2026-05-06 |
| Cantina | [Sky: Configurator Init Limits Function / PAS](https://cantina.xyz/portfolio/eb1f4d0a-4042-4a36-9606-7d753c1a9baf) | 2026-04-26 |
| Cantina | [Sky PAS](https://cantina.xyz/portfolio/cc1f6638-17a2-4a22-bdcb-695d933d00a8) | 2026-02-13 |

ChainSecurity reports are cumulative: each portfolio page hosts the latest version of the report, which covers all previously reviewed versions.

### Other reports

The following reports are not available on an auditor portfolio page and are kept in this repository:

- [Cantina (20261005-cantina-report-sky-pas.pdf)](./audit/20261005-cantina-report-sky-pas.pdf)
