// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// ControllerHarness.sol -- Certora harness standing in for a controller called by Configurator

pragma solidity ^0.8.24;

contract ControllerHarness {

    uint256 public calls;

    // The increments are unchecked so that this harness can never revert: a checked `calls++`
    // reverts once calls == type(uint256).max, which would make the `require(ok)` in
    // Configurator.callControllerAction an additional revert cause.

    function action() external {
        unchecked { calls++; }
    }
}
