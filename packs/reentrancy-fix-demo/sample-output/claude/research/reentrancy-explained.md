# Reentrancy Vulnerability in Solidity — Deep Dive

## What Is Reentrancy?

Reentrancy is a class of smart-contract vulnerability where an external call made
by a contract allows an attacker's contract to **call back into the victim** before
the victim's own execution has finished updating its state. The result: the victim
runs the same logic a second (or nth) time with stale, pre-update state — most
often draining funds it believes it still owes.

---

## The Vulnerable Code Shape

```solidity
// VULNERABLE — do NOT use
contract VulnerableVault {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "nothing to withdraw");

        // 1. External call FIRST — hands control to msg.sender
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");

        // 2. State update AFTER — never reached on re-entry
        balances[msg.sender] = 0;
    }
}
```

The flaw is the ordering: **external call before state update**. While control is
inside `msg.sender.call{...}`, the mapping entry still shows the full balance.

---

## The Attacker's Re-Entry Sequence

```solidity
contract Attacker {
    VulnerableVault public vault;

    constructor(address _vault) {
        vault = VulnerableVault(_vault);
    }

    // Step 1 — seed one legitimate deposit
    function attack() external payable {
        vault.deposit{value: msg.value}();
        vault.withdraw();           // trigger the drain
    }

    // Step 2 — fallback fires every time ETH arrives
    receive() external payable {
        if (address(vault).balance >= msg.value) {
            vault.withdraw();       // re-enter before balance is zeroed
        }
    }
}
```

### Step-by-step execution trace

| Call depth | Who runs          | `balances[attacker]` | Vault ETH balance |
|------------|-------------------|----------------------|-------------------|
| 1          | `Attacker.attack()` calls `vault.withdraw()` | 1 ETH       | 10 ETH            |
| 1→2        | Vault sends 1 ETH → triggers `Attacker.receive()` | still 1 ETH | 9 ETH |
| 2→3        | `receive()` calls `vault.withdraw()` again | still 1 ETH | 8 ETH |
| 3→4        | Another re-entry … | still 1 ETH | 7 ETH … |
| … (loop)   | Continues until vault is empty | still 1 ETH | 0 ETH |
| unwind     | `require(ok)` passes at every level | 1 ETH zeroed | 0 ETH |

After the call stack unwinds, `balances[attacker] = 0` finally runs — but the
vault is already drained.

---

## Why "State After Call" Is the Root Flaw

The EVM does not run transactions in parallel; within a single transaction,
however, **control flow can be re-entered** via external calls. The `call{}`
opcode hands the EVM execution context to an arbitrary address. If that address
is a contract with a `receive()` or `fallback()`, it executes synchronously in
the same transaction before the original frame resumes.

The consequence: any check on `balances[msg.sender]` that happens *after* the
call sees the **pre-update** value. The invariant `balance represents funds owed`
is broken inside the window of the external call.

---

## The Fix — Checks-Effects-Interactions (CEI) Pattern

Reorder so state is updated **before** making the external call:

```solidity
// SAFE — checks-effects-interactions order
function withdraw() external {
    uint256 amount = balances[msg.sender];   // CHECK
    require(amount > 0, "nothing to withdraw");

    balances[msg.sender] = 0;               // EFFECT (state update FIRST)

    (bool ok, ) = msg.sender.call{value: amount}("");  // INTERACTION last
    require(ok, "transfer failed");
}
```

Now a re-entrant call sees `balances[attacker] == 0` and the `require` reverts
immediately. The drain loop is broken.

### Additional mitigation — ReentrancyGuard

OpenZeppelin's `ReentrancyGuard` adds a mutex via a `_status` flag:

```solidity
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract SafeVault is ReentrancyGuard {
    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        balances[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
    }
}
```

`nonReentrant` sets a flag at entry and reverts if the flag is already set,
preventing any re-entrant call regardless of the state-update order. CEI is
still recommended even when using the guard — defence-in-depth.

---

## Real-World Incidents

### 1. The DAO Hack — June 2016

**Impact:** ~3.6 million ETH drained (~$60 M at the time; ~$10 B at 2021 prices).

The DAO ("Decentralised Autonomous Organisation") was a venture-fund smart
contract on Ethereum. Its `splitDAO` function sent ETH to a sub-DAO *before*
reducing the attacker's token balance. An attacker deployed a malicious contract
that repeatedly re-entered `splitDAO`, draining funds in a loop identical to the
pattern above.

The incident was so severe it caused a contentious hard fork of Ethereum itself:
the main chain was rolled back to return funds (Ethereum as it is today), while a
faction that rejected the rollback continued as **Ethereum Classic (ETC)**.

The DAO hack remains the canonical example used in every Solidity security course
because it demonstrates that reentrancy can destroy a protocol entirely — not just
a single user's funds.

### 2. Lendf.Me (dForce) — April 2020

**Impact:** ~$25 M drained.

The attacker used an ERC-777 token (imBTC) which fires a callback on token
transfer. The `supply()` function in Lendf.Me called the token transfer *before*
updating internal accounting — an ERC-777 flavour of reentrancy sometimes called
a **cross-function reentrancy** attack. The root cause is identical: state was
stale during an external call.

Funds were ultimately returned after the attacker was identified, but the
episode showed reentrancy extends beyond plain ETH transfers to any external
interaction that triggers a callback (ERC-777 `tokensReceived`, flash-loan
callbacks, etc.).

---

## Summary

| Concept | Detail |
|---------|--------|
| Root cause | External call made before state update |
| Attack vector | Malicious `receive()` / `fallback()` re-calls victim |
| EVM mechanism | `call{}` is synchronous; re-entry runs in same tx |
| Fix 1 | Checks-Effects-Interactions ordering |
| Fix 2 | `ReentrancyGuard` / `nonReentrant` mutex |
| Fix 3 | Pull-over-push (let users pull funds, don't push) |
| Canonical incident | The DAO, June 2016 (~3.6 M ETH) |
| Second example | dForce / Lendf.Me, April 2020 (~$25 M, ERC-777) |
