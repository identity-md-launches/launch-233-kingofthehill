# Crown (CRWN) and KingOfTheHill

An `evm_project` launch for Sepolia (chain id 11155111): the fixed-supply launch token **Crown (CRWN)**
and one application contract, **KingOfTheHill**, a round-based king-of-the-hill game paid in CRWN.

| Contract        | File                     | Constructor args | Notes                                     |
| --------------- | ------------------------ | ---------------- | ----------------------------------------- |
| `LaunchToken`   | `src/LaunchToken.sol`    | none             | Crown / CRWN, 18 decimals, 10^27 minted   |
| `KingOfTheHill` | `src/KingOfTheHill.sol`  | `["$token"]`     | immutable CRWN address, no owner, no ETH  |

ABI exports: `docs/abi/LaunchToken.json`, `docs/abi/KingOfTheHill.json`.

## The token

`LaunchToken` is an OpenZeppelin ERC-20 named `Crown`, symbol `CRWN`, 18 decimals. Its constructor takes no
arguments and mints exactly 1,000,000,000 CRWN (`10^27` minor units) to `msg.sender`, which is the project
factory at launch. There is no mint, burn hook, owner, pause, blocklist, fee or upgrade path; after
deployment it is plain ERC-20. The factory sends the supply to the launch pool and the reward distributor,
so no application contract holds CRWN at deployment. Players obtain CRWN by swapping Sepolia ETH in the
launch pool.

## The game

KingOfTheHill is played in rounds. All constants are fixed in code:

| Constant          | Value          |
| ----------------- | -------------- |
| `MIN_FIRST_CLAIM` | 1,000 CRWN     |
| `RAISE_PERCENT`   | 110            |
| `BONUS_PERCENT`   | 5              |
| `ROUND_DURATION`  | 24 hours       |

State: `round` (starts at 1), `king`, `kingPayment`, `pot`, `lastClaimAt`, plus a private per-address
credit read through `withdrawable(address)`.

### Rules

**claim(amount)**. The caller must first `approve` the game on CRWN; the game pulls `amount` with
`SafeERC20.safeTransferFrom`.

- First claim of a round (no king yet): `amount >= 1,000 CRWN`. The whole amount goes to the pot. No bonus.
  There is no time limit on the first claim.
- Later claims: `amount >= ceil(kingPayment * 110 / 100)` (read it from `minNextClaim()`), the caller must
  not be the current king, and `block.timestamp < lastClaimAt + 24 hours`. The claim is split at once:
  - the dethroned king is credited `kingPayment + bonus`, where `bonus = floor(amount * 5 / 100)`;
  - `amount - kingPayment - bonus` goes to the pot. It is never negative: the minimum raise leaves at least
    4.5% of `kingPayment` for the pot.
- Every accepted claim sets `king = msg.sender`, `kingPayment = amount`, `lastClaimAt = block.timestamp`.
  `kingPayment` only records what the current king paid; it is not escrowed, because it has already been
  split between the previous king and the pot.

**settle()**. Anyone, once the round has a king and `block.timestamp >= lastClaimAt + 24 hours`. The exact
boundary belongs to settle, not claim. The king is credited the pot (the pot only, not pot plus payment).
`king`, `kingPayment` and `pot` are cleared and `round` is incremented; the next round's first claim needs
1,000 CRWN again. `settle()` with no king reverts. `lastClaimAt` is left as the last claim's timestamp;
`deadline()` reports 0 while there is no king.

**withdraw()**. Pays the caller's full credited CRWN and zeroes it. Reverts with `NothingToWithdraw` when
the credit is zero. Nothing is ever pushed to a third party: a king that is a contract, that reverts or
that never withdraws cannot block anyone else.

### Economics and the stake

Within a round the pot always equals the current king's payment minus every bonus paid in that round.
Consequences:

- A dethroned king always gets back more than they paid (their payment plus 5% of the claim that beat them).
- The last king of a round wins the pot. If they were the round's only claimant, that is exactly their
  payment. Otherwise it is less than their payment: after a long chain of exact 110% claims the pot
  converges to about 45% of the last payment. That loss is the game's stake, and the website must say so.
- Payouts can never exceed payments. Every CRWN paid in is either credited to a dethroned king, credited
  to a settled king, or sits in the pot: `CRWN held == sum(withdrawable) + pot` at all times.

Worked example, one round: A claims 1,000. B claims 1,100: A is credited 1,055, pot is 1,045. A claims
1,210: B is credited 1,160.5, pot is 1,094.5. Nobody claims for 24 hours, anyone settles: A is credited
1,094.5 more (total 2,149.5 on 2,210 paid). Held CRWN is 3,310 = 2,149.5 + 1,160.5.

### Interface

Functions: `claim(uint256)`, `settle()`, `withdraw()`, `token()`, `round()`, `king()`, `kingPayment()`,
`minNextClaim()`, `pot()`, `deadline()`, `lastClaimAt()`, `withdrawable(address)` and the four constants.
No payable function, no `receive`, no `fallback`: the contract never holds ETH.

Events: `Claimed(round, king, amount, dethroned, bonus)` (dethroned is the zero address and bonus is 0 for a
round's first claim), `Settled(round, king, prize)`, `Withdrawn(account, amount)`.

Errors: `ZeroToken`, `BelowMinimum(amount, minimum)`, `AlreadyKing`, `RoundOver(deadline)`,
`RoundActive(deadline)`, `NoKing`, `NothingToWithdraw`.

## Assumptions

- CRWN is the plain OpenZeppelin ERC-20 in this repository: no transfer fee, no rebasing, no callbacks.
  The game trusts the `amount` argument rather than measuring balance deltas because of this. It is bound
  to one token address forever through an immutable.
- `block.timestamp` gates the 24-hour deadline. A builder can shift a block by a few seconds, so a claim
  within seconds of the deadline may land on either side of it. The deadline is 24 hours, so this drift is
  immaterial to the game, and the boundary is defined exactly: `< deadline` claims, `>= deadline` settles.
- There is no randomness, oracle, keeper or off-chain component. `settle()` is permissionless, so the round
  ends only when someone calls it; until then the king's prize simply waits in the pot and no claim can
  change it. The website offers a Settle button for this.
- No owner, admin, pause or upgrade exists. Nobody can recover tokens sent to the contract by mistake
  (a direct `transfer` of CRWN to the game, rather than a `claim`, is unrecoverable and is not counted in
  the pot). Only ever pay through `claim`.
- Sums are bounded by the CRWN supply (10^27), so `kingPayment * 110` and every credit stay far below
  `uint256` limits.

## Deployment parameters

Deployment is performed by the network's ProjectFactory from `launch.json`, which a separate manifest
assignment writes. The values this source requires:

- kind `evm_project`, chain id `11155111` (Sepolia), launch token `LaunchToken` (`src/LaunchToken.sol`),
  18 decimals, supply `1000000000000000000000000000`.
- contracts, in order: `KingOfTheHill` from `src/KingOfTheHill.sol` with `constructorArgs: ["$token"]`.
  It has no owner parameter, so `$owner` is not used anywhere.
- Pool: no hook, paired against native ETH, fee 3000, tick spacing 60, initial sqrtPriceX96
  `79228162514264337593543950336` (the effective opening price comes from the pinned policy).
- `foundry.toml`: `solc = "0.8.26"`, `evm_version = "paris"`, optimizer on with 200 runs,
  `bytecode_hash = "none"`, `ffi = false`, `fs_permissions = []`.

The constructor runs with the factory as `msg.sender`. KingOfTheHill does not read `msg.sender` in its
constructor, holds nothing at deployment and needs no initialisation call.

`script/Deploy.s.sol` is a reference rehearsal for a local Anvil fork only. It reads no keys and no RPC
URL. Its only input is `EXPECTED_CHAIN_ID`, which must be `0` (dry run), `31337` or `11155111`, and it
performs exactly one token and one game deployment between the broadcast markers.

## Build and verify (offline)

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

All dependencies are vendored as ordinary files under `lib/` (forge-std 1.16.2, OpenZeppelin Contracts
5.7.0) and resolved through `remappings.txt`. No network access is needed at any step.

Operator-only rehearsal against a local node (never from a contributor seat, never with a real key):

```sh
EXPECTED_CHAIN_ID=31337 forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
```

## Tests

`test/LaunchToken.t.sol`: metadata, supply, exact transfers (unit and fuzz), rejected admin selectors.

`test/KingOfTheHill.t.sol`: constructor and token binding, ETH rejection, the 1,000 CRWN minimum, the
ceil(110%) boundary on an exact multiple and on a value that must round up, the 5% bonus rounding down, the
split accounting, a self-claim refused, a dethroned king reclaiming, claims one second before, at and after
the 24-hour boundary, settle before, at and after it, settle with and without a king, settle crediting the
pot only, the next round resetting to 1,000 CRWN, withdraw semantics, a king that is a contract, reentrancy
through a callback token blocked on `claim`, `settle` and `withdraw`, a single claimant winning back their
payment exactly, a long chain of exact claims leaving the last king about 45%, and fuzzed claim chains
that check conservation and the pot identity after every step.

`test/KingOfTheHill.invariant.t.sol`: a handler drives five players through random claims, settles,
withdrawals and time hops. Invariants: CRWN held equals the sum of withdrawable balances plus the pot;
while a round has a king the pot equals `kingPayment` minus the bonuses paid in that round; payouts never
exceed payments; `minNextClaim()` matches its definition; the game holds no ETH and rounds only advance.

`test/Deploy.t.sol`: the script's `deploy()` function and its chain guard, called directly.

Tests use no environment variables and no fixed caller assumptions, so they run in any order and in parallel.

## Operational responsibilities

- Nobody administers the game. There is no role to rotate, no parameter to tune, no pause to pull.
- Settlement is permissionless. If nobody calls `settle()` the round simply stays settleable; the king's
  prize is safe in the pot and nobody can claim over them after the deadline.
- Each player is responsible for approving the exact CRWN they mean to spend and for calling `withdraw()`
  to collect credits. Credits never expire.
- Tests passing is not an audit. The independent adversarial review is a separate assignment and should
  attack the rounding of the 110% minimum and the 5% bonus, the claim/settle boundary, a contract king,
  timestamp drift near the deadline, and whether any sequence pays out more CRWN than was paid in.
- The website (a later stage) reads the CRWN address from `token()`, shows the king, `minNextClaim()`,
  the pot and the `deadline()` countdown, lists claims from `Claimed` events, and must state that the last
  king's prize is normally less than their own payment and that CRWN comes from the launch pool.
