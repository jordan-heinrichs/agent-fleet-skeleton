# SafeVault — Reentrancy Fix Implementation

## Patched Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * SafeVault: ETH deposit/withdraw with reentrancy protection.
 *
 * Two independent defences applied together:
 *   1. Checks-Effects-Interactions (CEI) — state zeroed before the call.
 *   2. OpenZeppelin nonReentrant modifier — mutex blocks nested re-entry.
 */
contract SafeVault is ReentrancyGuard {
    mapping(address => uint256) public balances;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    // ── Deposit ────────────────────────────────────────────────────────────

    function deposit() external payable {
        require(msg.value > 0, "SafeVault: zero deposit");
        balances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    // ── Withdraw ───────────────────────────────────────────────────────────

    /// @notice Withdraw the caller's full balance.
    /// nonReentrant: reverts if this function is called again before it returns.
    function withdraw() external nonReentrant {
        // CHECKS
        uint256 amount = balances[msg.sender];
        require(amount > 0, "SafeVault: nothing to withdraw");

        // EFFECTS  ← state updated BEFORE the external call
        balances[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);

        // INTERACTIONS  ← external call last
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "SafeVault: transfer failed");
    }

    // ── View helpers ───────────────────────────────────────────────────────

    function totalLocked() external view returns (uint256) {
        return address(this).balance;
    }
}
```

---

## Changelog vs. Vulnerable Version

### Vulnerable pattern (before)

```solidity
function withdraw() external {
    uint256 amount = balances[msg.sender];
    (bool ok, ) = msg.sender.call{value: amount}("");   // external call FIRST
    require(ok);
    balances[msg.sender] = 0;                            // state update AFTER
}
```

The external call hands control to `msg.sender`. If `msg.sender` is a
contract, its `receive()` / `fallback()` can call `withdraw()` again before
`balances[msg.sender] = 0` runs, draining the vault repeatedly.

### What changed

| # | Change | Why |
|---|--------|-----|
| 1 | Inherited `ReentrancyGuard` from OpenZeppelin | Adds a `_status` mutex that flips to `_ENTERED` on entry and back to `_NOT_ENTERED` on exit; any nested call reverts immediately. |
| 2 | Added `nonReentrant` modifier to `withdraw()` | Activates the mutex for this function. Even if CEI is somehow bypassed, the guard catches it. |
| 3 | Moved `balances[msg.sender] = 0` **before** the `.call{value:}` | Implements the Checks-Effects-Interactions pattern: state is final before any external code runs, so a re-entrant call sees a zero balance and reverts at the `require(amount > 0)` check. |
| 4 | Added `require(amount > 0)` guard | Explicit check so the revert message is clear when balance is already zero. |
| 5 | Emitted `Withdrawn` event before the transfer | Keeps event emission in the Effects phase; the on-chain log is consistent with storage even if the transfer later fails. |
| 6 | Added `deposit()` with event + zero-value guard | Completes the contract so it is self-contained and compilable. |

### Defence-in-depth rationale

CEI alone is sufficient for this specific bug, but `nonReentrant` is cheap
(~2 300 gas overhead) and guards against future refactors that might
inadvertently re-introduce ordering mistakes. Using both is the recommended
practice for any function that transfers value.
