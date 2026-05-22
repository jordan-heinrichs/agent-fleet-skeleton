# Reentrancy Vulnerability Explained

## Introduction

Reentrancy is a critical security vulnerability that can be exploited in smart contracts, particularly those written in Solidity. This type of attack occurs when an external contract calls back into the vulnerable contract during its execution, allowing the attacker to repeatedly withdraw funds or manipulate state variables.

## The Vulnerable Code Shape

The classic reentrancy hole typically appears in a `withdraw()` function where the contract sends Ether before updating the caller's balance:

```solidity
function withdraw() external {
    uint256 amount = balances[msg.sender];
    (bool ok, ) = msg.sender.call{value: amount}("");   // external call FIRST
    require(ok);
    balances[msg.sender] = 0;                            // state update AFTER
}
```

## How the Attack Works

1. **Initial Call**: An attacker calls the `withdraw()` function of the vulnerable contract.
2. **State Query**: The contract queries the balance of the caller and stores it in a local variable (`amount`).
3. **External Call**: The contract sends Ether to the caller's address.
4. **Reentrancy**: If the caller is another contract, this contract can execute its fallback function or receive function, which calls back into the vulnerable contract's `withdraw()` function again before the original transaction completes.
5. **State Update**: After receiving the Ether, the contract updates the caller's balance to zero.

### Attacker's Re-entry Sequence

1. **First Call**: Attacker calls `withdraw()`.
2. **Balance Query**: Contract queries and stores attacker's balance (`amount`).
3. **Ether Transfer**: Contract sends Ether to attacker.
4. **Reentrancy Callback**: Attacker's contract calls back into `withdraw()` before the original transaction completes.
5. **Repeat Steps 2-4**: This process repeats until the contract runs out of gas or funds.

### Why State-after-Call is the Flaw

The flaw lies in the order of operations: the contract sends Ether (`call{value: amount}("")`) before updating the caller's balance (`balances[msg.sender] = 0`). This allows the attacker to repeatedly withdraw funds by making reentrant calls, draining the contract of its funds.

## Real-World Examples

### The DAO Hack (2016)

The most famous example of a reentrancy attack is the Ethereum Classic (ETC) fork known as "The DAO" in 2016. The attacker exploited a similar vulnerability in the DAO's `withdraw()` function, draining approximately $50 million worth of Ether.

- **Vulnerable Code**: The DAO contract did not follow the Checks-Effects-Interactions pattern.
- **Attack Vector**: The attacker created a malicious contract that called back into the DAO during the withdrawal process.
- **Impact**: The attack resulted in one of the largest thefts in cryptocurrency history, leading to the hard fork of Ethereum Classic.

### Other Incidents

1. **Parity Wallet Hack (2017)**: A reentrancy vulnerability in a Parity wallet allowed attackers to drain funds from multi-signature wallets.
2. **Coinbase Custody (2018)**: A similar attack exploited a reentrancy flaw in a smart contract used by Coinbase Custody, resulting in the theft of approximately $65 million.

## Preventing Reentrancy

To prevent reentrancy attacks, developers should follow best practices such as:

- **Checks-Effects-Interactions Pattern**: Ensure that all state changes are made before making any external calls.
- **OpenZeppelin `ReentrancyGuard`/`nonReentrant`**: Use OpenZeppelin's built-in mechanisms to guard against reentrancy attacks.
- **Pull-over-Push Payment Pattern**: Instead of pushing Ether to the caller, allow the caller to pull funds from the contract.

## Conclusion

Reentrancy is a serious security vulnerability that can lead to significant financial losses. By understanding how it works and following best practices, developers can protect their smart contracts from such attacks.
