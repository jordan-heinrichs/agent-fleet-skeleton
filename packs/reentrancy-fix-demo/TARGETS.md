# Targets — reentrancy-fix-demo

The single issue this demo solves, end to end:

## The issue
A Solidity vault with a `withdraw()` that sends ETH **before** zeroing the
caller's balance — the classic reentrancy hole.

```solidity
function withdraw() external {
    uint256 amount = balances[msg.sender];
    (bool ok, ) = msg.sender.call{value: amount}("");   // external call FIRST
    require(ok);
    balances[msg.sender] = 0;                            // state update AFTER
}
```

## Reference points
- The DAO hack (2016) — the canonical real-world reentrancy exploit
- Checks-Effects-Interactions pattern
- OpenZeppelin `ReentrancyGuard` / `nonReentrant`
- Pull-over-push payment pattern
