# World Cup On-Chain Betting

A parimutuel prediction market for World Cup outcomes, written in Solidity and built with
[Foundry](https://book.getfoundry.sh/).

Markets are created with a set of mutually exclusive outcomes; users stake collateral (native ETH or
an ERC20) on an outcome and receive shares priced by a proportional AMM. After a market's resolution
time, a designated arbitrator resolves it, and winners claim their share of the total pool minus a
2% platform fee. Open positions can also be traded on a peer-to-peer secondary market.

## Why Foundry

This project is delivered as a self-contained Foundry package rather than run inside a larger
third-party toolchain, for two reasons:

- **Supply-chain caution** — I avoid running unfamiliar, heavyweight repos locally as a matter of
  habit. A minimal, auditable Foundry project keeps the trusted surface small.
- **Toolchain fit** — for pure Solidity, Forge gives native Solidity tests, faster iteration, and
  fewer moving parts than a JS/TS harness.

The main contract keeps a stable public API (function names, `marketCount`, `getMarket`'s named
`status` return, and human-readable `require` revert strings), so it is also drop-in compatible with
a Hardhat test suite that exercises the same scenarios.

## Contracts

| Contract | Description |
| --- | --- |
| `src/WorldCupBetting.sol` | Core prediction market: markets, betting, resolution, claims, fees, and the secondary market. |
| `src/ReputationSystem.sol` | Tracks per-user reputation; `updateReputation` is called by the market on each settlement. |
| `src/MockERC20.sol` | Mintable ERC20 used to exercise the ERC20-collateral path in tests. |
| `src/interfaces/IReputationSystem.sol` | Interface the market uses to talk to the reputation system. |

## Design decisions

- **Checks-Effects-Interactions everywhere.** Every state-mutating function is structured as
  Checks → Effects → Interactions, and value-moving entry points (`claimWinnings`, `buyPosition`,
  `withdrawFees`) are `nonReentrant`.
- **Parimutuel payouts.** A winning bet receives `bet.shares * totalPool / totalWinningShares`. The
  whole pool (winning + losing stakes) is distributed among winners in proportion to their shares.
- **Fee model.** A 2% fee is taken from the *winning payout* (not from stakes), accrued per-token in
  `sCollectedFees`, and withdrawn by the owner via `withdrawFees`. All arithmetic stays in the
  token's base units (wei for ETH), so no fixed-point scaling is needed.
- **Secondary market funded by the buyer.** `buyPosition` pays the seller the listing price out of
  the buyer's `msg.value` (never from the pooled collateral), transfers ownership atomically, and
  refunds any excess. Listings are blocked once a market's resolution time passes.
- **Reputation on every settlement.** `claimWinnings` calls `updateReputation` for both winners and
  losers, and marks the bet claimed first so it can never be double-settled.
- **Storage naming.** Storage variables use an `s` prefix; the small set of getters the external API
  needs (e.g. `marketCount()`) are thin accessors over that storage.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)

## Setup

```bash
git clone <this-repo>
cd world_cup_bet
forge install        # pulls submodule dependencies (forge-std, openzeppelin-contracts)
```

## Build

```bash
forge build --skip PreditionMarket.sol
```

> `src/PreditionMarket.sol` is an unrelated work-in-progress reference contract and does not
> currently compile; `--skip` excludes it. The assessment lives entirely in `WorldCupBetting.sol`.

## Test

The Forge suite in `test/WorldCupBetting.t.sol` ports all nine assessment scenarios (A–I) — market
creation and resolution, net-of-fee payouts, fee withdrawal, timing and access-control reverts, the
slippage guard, the secondary market, the ERC20 lifecycle, and the losing/double-claim path.

```bash
forge test --skip PreditionMarket.sol -vv
```

Run a single scenario:

```bash
forge test --match-test test_ScenarioB_winnerNetPayoutAndFeeWithdraw -vvv
```

## Format

```bash
forge fmt          # apply formatting
forge fmt --check  # verify (CI)
```

## Scenario coverage

| ID | Scenario | Test |
| --- | --- | --- |
| A | Three-way (1X2) market created and resolved | `test_ScenarioA_createAndResolveThreeWay` |
| B | Winner paid net of fee; owner withdraws ETH fees | `test_ScenarioB_winnerNetPayoutAndFeeWithdraw` |
| C | Cannot resolve before resolution time | `test_ScenarioC_cannotResolveTooEarly` |
| D | Only the arbitrator may resolve | `test_ScenarioD_onlyArbitratorResolves` |
| E | No new bets at/after resolution time | `test_ScenarioE_noBetsAfterClose` |
| F | Slippage guard rejects when `minShares` too high | `test_ScenarioF_slippageGuard` |
| G | Secondary-market buyer claims the seller's winning ticket | `test_ScenarioG_secondaryMarketBuyerClaims` |
| H | Full lifecycle with ERC20 collateral | `test_ScenarioH_erc20Lifecycle` |
| I | Losing side settles for reputation; no double-claim | `test_ScenarioI_losingClaimNoDoubleClaim` |
