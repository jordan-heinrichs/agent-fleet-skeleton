# Reentrancy Fix Design

**Phase:** 2 — Solution Architecture  
**References phase-1 research:** `output/research/reentrancy-vulnerability-analysis.md`  
(Phase-1 researcher identified the classic pre-state-update external call pattern in the
target vault's `withdraw()`, tracing it to the 2016 DAO hack root cause.)

---

## The Vulnerability (recap)

```solidity
function withdraw() external {
    uint256 amount = balances[msg.sender];
    (bool ok, ) = msg.sender.call{value: amount}("");   // external call FIRST
    require(ok);
    balances[msg.sender] = 0;                            // state update AFTER ← bug
}
```

A malicious contract's `receive()` / `fallback()` can call `withdraw()` again
before `balances[msg.sender] = 0` executes, draining the vault repeatedly.
The DAO hack (June 2016, ~$60 M USD) is the canonical real-world instance of this
exact pattern.

---

## Three Standard Defenses

### 1. Checks-Effects-Interactions (CEI)

**Principle:** Reorder operations so all state mutations happen *before* any
external call. A reentering attacker finds no remaining balance to steal.

```solidity
function withdraw() external {
    uint256 amount = balances[msg.sender];
    require(amount > 0, "nothing to withdraw");   // Check
    balances[msg.sender] = 0;                      // Effect  ← zeroed FIRST
    (bool ok, ) = msg.sender.call{value: amount}(""); // Interaction
    require(ok, "transfer failed");
}
```

**Pros:** Zero gas overhead; no library dependency; idiomatic Solidity.  
**Cons:** Easy to violate accidentally in complex functions; offers no defence if
two *separate* state variables are involved (cross-function reentrancy).

---

### 2. Reentrancy Guard (Mutex)

**Principle:** A boolean or integer lock prevents re-entry into any guarded
function before the first call returns.

OpenZeppelin's `ReentrancyGuard` (the industry standard):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Vault is ReentrancyGuard {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "nothing to withdraw");
        balances[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
```

Internally, `nonReentrant` sets a `_status` slot to `ENTERED` on entry and back
to `NOT_ENTERED` on exit; a second entry reverts immediately.

**Pros:** Catches cross-function reentrancy; explicit and auditable; well-tested
OpenZeppelin implementation absorbs implementation risk.  
**Cons:** ~2 300 gas overhead per guarded call (one cold SSTORE + one warm SSTORE);
adds a dependency; can create deadlocks if two `nonReentrant` functions call each
other (use `_nonReentrantBefore` / `_nonReentrantAfter` sparingly for that case).

---

### 3. Pull-over-Push Payments

**Principle:** Instead of *pushing* ETH to the caller inside `withdraw()`,
record the owed amount in a mapping and let the recipient *pull* it in a separate
`claimPayment()` call. The vault never initiates an external call; there is
nothing to reenter.

```solidity
contract Vault {
    mapping(address => uint256) public pendingWithdrawals;

    // "withdraw" now just records the entitlement
    function requestWithdraw() external {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "nothing to withdraw");
        balances[msg.sender] = 0;
        pendingWithdrawals[msg.sender] += amount;
    }

    // caller pulls their own funds; attacker's reentry finds 0 pending
    function claimPayment() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "nothing to claim");
        pendingWithdrawals[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
```

**Pros:** Architecturally eliminates push-reentrancy risk; also improves UX for
multi-recipient scenarios (each recipient claims independently; one failure does
not block others).  
**Cons:** Adds an extra transaction for recipients; higher UX friction for simple
single-recipient withdrawals; still requires CEI ordering inside `claimPayment`.

---

## Recommendation

### Use CEI + `nonReentrant` together

For this vault, the **recommended fix** is:

1. **Apply CEI ordering** — zero `balances[msg.sender]` before the `.call`.
   This is the minimal, zero-cost fix that eliminates the root cause.

2. **Add `nonReentrant`** — inherit `ReentrancyGuard` and decorate `withdraw`
   with `nonReentrant`. This is defence-in-depth: if a future refactor
   accidentally re-introduces an ordering mistake, or a cross-function path
   opens up, the mutex catches it.

Pull-over-push is the right architecture for *payment disbursement* contracts
(e.g., auction settlements, multi-beneficiary splits). For a simple personal
vault where the caller withdraws their own balance, the added transaction cost
and UX friction are not justified.

### Final fixed contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Vault is ReentrancyGuard {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "nothing to withdraw");
        balances[msg.sender] = 0;                          // Effect before Interaction
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
```

**Why this beats the original:**
- State is zeroed before the external call; a reentering attacker reads `0`.
- `nonReentrant` reverts any reentry attempt at the EVM level regardless.
- Two independent layers must both fail for an attacker to succeed — defence-in-depth.
- Gas increase: ~2 300 gas/call (acceptable for a withdrawal operation).

---

## Decision Matrix

| Defense              | Gas cost  | Cross-function | Complexity | Recommended for vault |
|----------------------|-----------|----------------|------------|-----------------------|
| CEI ordering         | 0         | No             | Low        | Yes (primary fix)     |
| Reentrancy guard     | ~2 300    | Yes            | Low        | Yes (defence-in-depth)|
| Pull-over-push       | +1 tx     | Yes            | Medium     | No (UX tradeoff)      |

---

*Solution authored by role: solution-architect, fire #1.*
