// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

interface ConfiguratorLike {
    function addDefault(bytes32, uint256, uint256) external;
    function delDefault(bytes32) external;
    function addPrime(bytes32, address) external;
    function delPrime(bytes32) external;
    function initRateLimit(bytes32, bytes32) external;
    function setRateLimit(bytes32, bytes32, uint256, uint256) external;
}

abstract contract Role {
    address immutable public owner;
    ConfiguratorLike immutable public configurator;

    modifier onlyOwner() {
        require(msg.sender == owner, "Role/not-owner");
        _;
    }

    constructor(address owner_, address configurator_) {
        owner = owner_;
        configurator = ConfiguratorLike(configurator_);
    }
}

contract TimeLocked is Role {
    constructor(address owner_, address configurator_) Role(owner_, configurator_) {
    }

    function addDefault(bytes32 key, uint256 maxAmount, uint256 slope) external onlyOwner {
        configurator.addDefault(key, maxAmount, slope);
    }

    function delDefault(bytes32 key) external onlyOwner {
        configurator.delDefault(key);
    }

    function addPrime(bytes32 prime, address rateLimits) external onlyOwner {
        configurator.addPrime(prime, rateLimits);
    }

    function delPrime(bytes32 prime) external onlyOwner {
        configurator.delPrime(prime);
    }
}

contract GovOps is Role {
    constructor(address owner_, address configurator_) Role(owner_, configurator_) {
    }

    function initRateLimit(bytes32 prime, bytes32 key) external onlyOwner {
        configurator.initRateLimit(prime, key);
    }

    function setRateLimit(bytes32 prime, bytes32 key, uint256 maxAmount, uint256 slope) external onlyOwner {
        configurator.setRateLimit(prime, key, maxAmount, slope);
    }
}
