# Notes and Trust Assumptions

- The following entities are trusted:
  - **Timelock**: Fully trusted.
  - **Core Council**: Very highly trusted.
  - **cBEAMs**: Mostly trusted (a trusted team's multisig, malicious activity is assumed to be of very low likelihood).

- It is assumed proposers or cancelers would not cancel proposals maliciously (including Core Council).
- It is assumed that before adding calldata, rate limits, or whitelisting targets, security related scenarios are thoroughly considered.
- As part of the above considerations, possible misalignment of cBEAMs is expected to be taken into consideration (although unlikely). For example:
  1. Omission - not executing a call when expected
  2. Double execution - executing the same call twice
  3. Stale execution - executing an old call after a newer one superseded it
  4. Reordering - executing calls in the wrong order
- It is also expected to be considered whether cBEAMs can block withdrawals in case of emergencies (for example, when needed, infinity rate limit would be configured).
- It is assumed the Core Council would not block withdrawals or emergency mechanisms on purpose.
- It is expected to be considered whether a default rate limits / calldata can be applied simultaneously on many controllers, thus amplifying potential harm. For example, the damage of depositing into a new vault without applying slippage protection might be amplified if it can be done for all whitelisted controllers. In general it is assumed that as the system scales more protections are added for such scenarios.
- It is assumed that cBEAMs and Core Council are synced in their operations, including timing their actions against Timelock executions.
- It is assumed the cancelers are available on short notice to remove proposals if needed. This includes removing old calldata/rate-limits in a timely manner.
- As with other Sky contracts, a mom mechanism is not expected to be deployed on remote chains. It is expected to be sufficiently replaced with highly secured and trusted multisigs.

