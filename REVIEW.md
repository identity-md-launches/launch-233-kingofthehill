# Builder-side review of Crown (CRWN) and KingOfTheHill

This is the implementer's own adversarial pass over `src/LaunchToken.sol` and `src/KingOfTheHill.sol`,
written before hand-off. It is **not** the independent adversarial review the workflow requires; that
review is a separate assignment and should treat everything below as claims to be attacked, not as
conclusions.

## Scope re-run

- `forge build --offline`: clean, solc 0.8.26, evm paris, optimizer 200 runs, `bytecode_hash = "none"`.
- `forge test --offline`: 51 tests pass (3 deploy, 6 token, 37 game unit/fuzz, 5 invariants at 64 runs
  x 64 depth).
- `forge fmt --check`: clean.
- `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline`: runs, one token and one game.
- KingOfTheHill runtime is 2,326 bytes, far under EIP-170; a manual read of the source shows no
  `delegatecall`, `callcode` or `selfdestruct`, no proxy, no assembly.
- The protected floor tests (`Project.protected.t.sol`, `Token.protected.t.sol`) were rehearsed locally
  with CREATE2 addresses computed for a stand-in factory: all 8 pass against this creation code.

## Attack surface walked

### Rounding of the 110% minimum and the 5% bonus

- `minNextClaim()` returns `(kingPayment * 110 + 99) / 100`, the exact ceiling. Tested on an exact
  multiple (1,000 -> 1,100) and on `1,000 CRWN + 1 wei` (-> `1,100 CRWN + 2 wei`), plus a fuzz that checks
  `m` is the least integer with `100 m >= 110 p` and that `m - 1` is refused.
- `bonus = amount * 5 / 100` rounds down, so the pot receives the dust. With `amount >= ceil(1.1 p)`,
  `amount - p - bonus >= 0.95 * 1.1 p - p = 0.045 p > 0`, so the pot share never underflows. The fuzz
  asserts the remainder is at least 4.5% of `p` (to within 1 wei of rounding). No path lets a claimer make
  the previous king's credit exceed `p + 0.05 amount`, and farming rounding by repeated claims only ever
  gives the pot a wei, never a player.
- Overflow: every product is bounded by `10^27 * 110`, far below `2^256`.

### The claim/settle boundary

- `claim` requires `block.timestamp < lastClaimAt + 24h`; `settle` requires `>=`. At the exact second
  only settle is possible; one second earlier only claim is possible. Both are unit tested and fuzzed over
  offsets 0 to 72 hours. There is no window where both or neither are allowed while a king exists.
- The first claim of a round has no deadline, so a round cannot expire before it starts; `settle()` reverts
  with `NoKing` in that state, tested before and after a settlement.
- A claim in the last second extends the deadline by a full 24 hours from that claim. This is the intended
  rule and is tested.
- `lastClaimAt` is not cleared at settle. `deadline()` returns 0 without a king, and `claim` ignores
  `lastClaimAt` when there is no king, so the stale value has no effect. Flagged for the reviewer as a
  cosmetic choice, not a bug.

### A king that is a contract

- No CRWN is ever pushed. `claim` credits the dethroned king in storage and `settle` credits the king in
  storage. The only outgoing transfer is in `withdraw`, to `msg.sender`, after the credit is zeroed.
  A contract king that reverts, has no code, or never withdraws blocks nobody (tested: another player
  claims, settles and withdraws while the contract king holds credit).
- All three state-changing functions are `nonReentrant` and follow checks-effects-interactions. With
  CRWN (no callbacks) reentrancy is unreachable; with a callback token standing in, reentrant `claim`,
  `settle` and `withdraw` attempts during a transfer are shown to fail without altering state.

### Timestamp drift near the deadline

- A builder shifting a block by a few seconds can move a claim from just-before to just-after the deadline
  or vice versa. The effect is bounded to that single claim: the deadline itself is derived from the
  accepted claim's timestamp, and the round is 24 hours, so drift cannot manufacture a settlement or a
  claim that the honest timeline would not have allowed within seconds. Documented in the README as an
  accepted limitation; no on-chain mitigation is possible without changing the rules.

### Can any sequence pay out more than was paid in?

- Conservation is enforced structurally: every unit of an accepted `amount` is assigned exactly once, to
  the dethroned king's credit or to the pot, before the transfer is pulled. Settle moves the pot to a
  credit. Withdraw moves a credit out. Nothing else changes balances.
- Unit tests, a fuzzed claim chain (up to 40 claims, 3 players, random amounts and gaps) and the invariant
  suite all assert `held == sum(withdrawable) + pot` and `paidOut + held == paidIn` after every step, and
  that draining every credit at the end leaves the contract at zero with the total paid out equal to the
  total paid in.
- `kingPayment` is never added to a credit at settlement, so the "king gets pot + payment" double-count
  the spec warns about is absent (tested explicitly).

### Other checks

- Access: no owner, no privileged path, no `msg.sender` use in the constructor, no `tx.origin`.
- Value in: `safeTransferFrom` is the only inflow. A `claim` without allowance or balance reverts before
  any state is kept (the revert unwinds the effects). ETH is rejected on every path (no payable function).
- Value out: only `withdraw`, only to the caller, only their own credit.
- Token assumptions: CRWN is a plain OpenZeppelin ERC-20 with no fee or callbacks, so trusting `amount`
  is sound for this deployment. Binding the game to a different token with fees would break the
  conservation invariant; the immutable prevents that after deployment.
- Griefing: a claim of a huge amount raises the bar for everyone else and, absent a challenger, returns
  to the claimer at settlement minus the bonuses already paid. That is the game, not an exploit. There is
  no way to lock another player's credit.
- Token: OpenZeppelin ERC-20 5.7.0, no extra functions, mint only in the constructor to `msg.sender`;
  the launch floor's selector list (`mint`, `setOwner`, `upgradeTo`, `initialize`, ...) all revert.

## Findings and disposition

| # | Severity | Finding                                                                  | Disposition            |
| - | -------- | ------------------------------------------------------------------------ | ---------------------- |
| 1 | Info     | `lastClaimAt` keeps its last value after settle; harmless, `deadline()` masks it | Documented, unchanged |
| 2 | Info     | CRWN sent by plain `transfer` (not `claim`) is stuck and not in the pot  | Documented in README   |
| 3 | Info     | Deadline is timestamp-based; drift of a few seconds is accepted          | Documented in README   |
| 4 | Info     | The last king of a contested round loses part of their payment by design | Documented; site must say so |

No medium or high findings from this pass. The independent reviewer should still try to break the four
attack lines above with their own inputs rather than rely on these tests.

## Untested edges (for the independent reviewer)

- Claim amounts near `10^27` (the whole supply) are covered only by the arithmetic argument, not by a
  test, because no single player can hold more than the supply.
- The invariant handler caps claims at three times the minimum and time hops at 30 hours; longer gaps
  and larger raises are exercised only in the unit fuzz.
