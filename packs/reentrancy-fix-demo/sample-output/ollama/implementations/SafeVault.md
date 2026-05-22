# SafeVault Implementation

## Fixed Solidity Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract SafeVault is ReentrancyGuard {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        require(msg.value > 0, "Deposit amount must be greater than zero");
        balances[msg.sender] += msg.value;
    }

    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "Insufficient balance");

        // Effect: Update state before interaction
        balances[msg.sender] = 0;

        // Interaction: Send ETH to the caller
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Withdrawal failed");
    }
}
```

## Changelog

1. **Reentrancy Guard**: Added `ReentrancyGuard` from OpenZeppelin to prevent reentrancy attacks.
2. **State Update Before Interaction**: Modified the `withdraw()` function to update the caller's balance (`balances[msg.sender] = 0`) before making the external call to send ETH. This follows the Checks-Effects-Interactions pattern, ensuring that state changes occur before any external interactions.

## Explanation

The original contract was vulnerable to reentrancy attacks because it sent ETH to the caller before zeroing their balance. An attacker could exploit this by calling `withdraw()` multiple times within a single transaction, draining the vault's funds.

By applying the OpenZeppelin `ReentrancyGuard` and following the Checks-Effects-Interactions pattern, the contract now safely handles withdrawals without risking reentrancy attacks. The state update (`balances[msg.sender] = 0`) is performed before any external calls, ensuring that the balance is zeroed out before the ETH transfer occurs.
