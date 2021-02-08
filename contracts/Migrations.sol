// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

contract Migrations {
    address public owner;
    uint256 public last_completed_migration;

    modifier restricted() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setCompleted(uint256 completed) public restricted {
        last_completed_migration = completed;
    }
}
