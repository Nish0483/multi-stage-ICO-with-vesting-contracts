# Multistage ICO with Vesting

Foundry repo for a 5-stage token sale. Buyers pay in native ETH or ERC-20 (Chainlink USD price). Tokens go into a vesting vault instead of the wallet. There's also a separate contract for founder/team tokens.

Contracts:

- `src/ICO_vesting.sol` — sale logic, stages, KYC, cross-stage buys
- `src/Vesting.sol` — investor vesting vault
- `src/TeamVestingLock.sol` — founder lock (1y cliff, 3y vest)
- `src/ICO_directSell.sol` — old/simple single-price sale, instant transfer, no vesting

## How it's wired

Two contracts handle the public sale. They do different jobs.

**ICO** — takes payment and records who bought what.
**VestingVault** — holds the actual ICO tokens and releases them over time.

When someone buys:

1. They send ETH or ERC-20 to the **ICO** contract.
2. The ICO calculates how many tokens they get (oracle price × stage price).
3. Instead of sending tokens to the buyer, the ICO tells the vault: "this address owns X tokens from round Y" (`addSchedule`).
4. Later, after vesting starts, the buyer calls **claim** on the vault to pull out what's unlocked.

So payment stays in the ICO. Tokens stay in the vault until claimed.

```
Buyer pays ETH/USDC
        ↓
      [ ICO ]  ── records purchase, keeps payment
        ↓ addSchedule(user, round, amount)
  [ VestingVault ]  ── holds tokens, enforces cliff/duration
        ↓ claimRound / claimAll
      Buyer wallet
```

Before the sale opens, admin deposits all sale tokens into the vault. The ICO only has permission to add schedules — it can't pull tokens out.

**TeamVestingLock** is a third contract for founder tokens. Same idea (lock then claim) but completely separate from the ICO flow.

## Stages

Stage count = length of the `Stage[]` you pass to the ICO constructor (and matching `RoundConfig[]` on the vault). No separate “number of stages” param — just add or remove array entries. Default 5-stage setup is in `src/IcoDeploymentConfig.sol`.

5 stages, 30 days each (150 days total) in the default config. Total cap: 200T tokens (18 decimals).

A stage ends when its cap is hit **or** its end time passes. `_updateStage()` runs on every buy and moves `currentStage` forward. `getEffectiveStage()` does the same check without writing state.

| # | Cap | Price | Min buy | Ends |
|---|-----|-------|---------|------|
| 0 Private | 50T | $0.000010 | $100 | start + 30d |
| 1 Presale | 50T | $0.000012 | $50 | start + 60d |
| 2 Crowdsale 1 | 30T | $0.000014 | $10 | start + 90d |
| 3 Crowdsale 2 | 30T | $0.000016 | $10 | start + 120d |
| 4 Final | 40T | $0.000018 | $10 | start + 150d |

On-chain prices use scaled values (e.g. `10e12` for $0.000010).

## Buying

Only KYC-approved wallets can buy (`verifyUser` / `revokeVerifiedUser` on the verifier role).

1. Payment → USD via Chainlink feed (`address(0)` = native)
2. USD ÷ stage price → token amount
3. Must meet that stage's min purchase (whole USD)
4. If it fits the remaining cap, one vesting schedule is added for that round
5. If it doesn't fit → cross-stage buy (below)

Entry points: `buyTokenWithNative()`, `buyTokenWithERC20(token, amount)`.

Oracle data must be fresh — default max age is 4 hours (`stalenessThreshold`).

Tokens never go straight to the buyer. The ICO calls `vestingVault.addSchedule(user, round, amount + bonus)`.

## Cross-stage buy

If someone tries to buy more than what's left in the current stage, the contract splits the order across stages in one tx:

1. Fill current stage to cap → schedule at stage N price + vesting rules
2. Advance stage
3. Spend leftover payment in the next stage(s), same thing per chunk
4. Refund unused ETH (native only)

Things to know:

- Each chunk gets priced and vested under its own stage. Spillover into stage 1 costs stage 1 price, not stage 0.
- The 3% volume bonus is calculated per chunk, not once on the full payment.
- Rollover stops if leftover payment can't meet the next stage's minimum.
- ERC-20 has no refund path — if the remainder is below the next min, it just sits unspent.
- Once every stage is sold out, buys revert with `StageCapReached`.

Example: big ETH buy near end of stage 0 fills the rest of stage 0 (90d cliff, 10% TGE), rolls into stage 1 at the higher price (30d cliff, 20% TGE), two separate schedules on the same wallet.

## Volume bonus

Chunks of 10M+ tokens get 3% extra (`checkBonus`). Bonus is part of the vesting schedule for that round.

## Vesting (investors)

Vault must be funded before sales — `addSchedule` reverts if balance < `totalAllocated + amount`.

After the ICO ends, admin calls `ICO.startVesting(timestamp)` which sets the clock on the vault. Users claim with `claimRound(round)` or `claimAll()`.

Per-round config (set in vault constructor):

| Round | Cliff | Duration | TGE |
|-------|-------|----------|-----|
| 0 | 90d | 360d | 10% |
| 1 | 30d | 180d | 20% |
| 2 | 15d | 90d | 30% |
| 3 | 0 | 30d | 60% |
| 4 | 0 | 0 | 100% |

Vesting math: TGE unlocks at start. Linear accrual runs from `vestingStartTime`, but during the cliff only TGE is claimable — everything accrued in the cliff unlocks in one lump when the cliff ends. Round 4 is fully unlocked at TGE.

Repeat buys in the same round aggregate into one schedule.

Admin can `depositICOTokens`, `withdrawIcoTokens` (unallocated surplus only), pause claims.

## Team vesting

`TeamVestingLock` — founder deposits up to `FOUNDER_ALLOCATION`, calls `startVesting()` once, then `claim()` over time.

- 1 year cliff (nothing before that)
- 3 year total duration, linear after cliff
- No TGE
- `Ownable2Step`, renounce disabled

## Roles

**ICO:** `DEFAULT_ADMIN_ROLE` (config, withdraw, pause, start vesting), `VERIFIER_ROLE` (KYC)

**VestingVault:** `DEFAULT_ADMIN_ROLE` (deposit, withdraw, pause), `ALLOCATOR_ROLE` (ICO only, for `addSchedule`)

## Deploy order

Stage caps, prices, min buys, end times, and vesting rules are passed into the constructors — nothing is hardcoded in the contracts. Default values live in `src/IcoDeploymentConfig.sol`; edit that file (or build your own arrays) and pass the same length/config into both deploy calls.

```
1. Deploy token
2. Build `RoundConfig[]` and `Stage[]` (same length — that length is your stage count)
3. Deploy VestingVault(token, roundConfigs)
4. Deploy ICO(token, startTime, vault, verifier, paymentConfigs, stages)
5. vault.grantRole(ALLOCATOR_ROLE, ico)
6. vault.depositICOTokens(allocation)
7. KYC users → sale runs → startVesting → users claim
```

Foundry script: `script/DeployIco.s.sol` (uses `IcoDeploymentConfig` by default).

```bash
ICO_TOKEN=0x... NATIVE_FEED=0x... USDT=0x... USDT_FEED=0x... \
  forge script script/DeployIco.s.sol --rpc-url <url> --broadcast
```

## Tests

```bash
forge test
forge test -vvv
forge test --match-path test/ICO_FullSuite.t.sol
forge test --match-path test/TeamVestingLock.t.sol
```

`ICO_FullSuite.t.sol` covers purchases, cross-buy rollover/refunds, stage transitions, vesting claims, KYC, oracle checks, reentrancy on ETH refund.

## ICO_directSell

Single price, 30-day window, tokens sent immediately. No stages, no KYC, no vesting. Useful as a simpler reference — the main sale is `ICO` + `VestingVault`.
