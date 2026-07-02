# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack

Solidity smart contracts built with [Foundry](https://book.getfoundry.sh/). Dependencies managed via git submodules: `forge-std`, `openzeppelin-contracts-upgradeable`, `openzeppelin-foundry-upgrades`.

## Commands

```bash
forge build --sizes      # compile and show contract sizes
forge test -vvv          # run all tests with traces
forge test --match-test <TestName> -vvv   # run a single test
forge fmt                # format Solidity files
forge fmt --check        # check formatting (used in CI)
forge snapshot           # generate gas snapshots
anvil                    # local EVM node for manual testing
```

## CI

GitHub Actions (`.github/workflows/test.yml`) runs on every push/PR:
1. `forge fmt --check`
2. `forge build --sizes`
3. `forge test -vvv`

All three must pass. Format is enforced — run `forge fmt` before committing.

## Architecture

### PredictionMarket (`src/PreditionMarket.sol`)

Core contract — inherits OpenZeppelin `ReentrancyGuard` and `Ownable`. Supports both ETH and ERC20 markets (`tokenAddress == address(0)` means ETH).

**Lifecycle:**
1. Anyone calls `createMarket()` — specifies outcomes array, resolution timestamp, and an arbitrator address
2. Users call `placeBet(marketId, outcomeIndex, amount, minShares)` — sends ETH or pre-approved ERC20
3. After `resolutionTime`, the designated arbitrator calls `resolveMarket(marketId, winningOutcome)`
4. Winners call `claimWinnings(betId)` — receives payout minus 2% platform fee; losers calling it just marks their bet claimed and updates reputation

**Share pricing:** Custom proportional AMM. `calculateShares()` prices shares based on the current pool size for the chosen outcome relative to total pool — earlier bets on less-popular outcomes receive more shares. `getPrice()` returns the implied probability as a percentage (0–100).

**Secondary market:** Bet holders can `listPosition(betId, price)` and `cancelListing(betId)`. Buyers call `buyPosition(betId)` paying in the market's token type; ownership transfers atomically.

**External dependency — `IReputationSystem`:** `PredictionMarket` calls `updateReputation(user, correct)` on a separate contract passed at construction time. This interface is declared in the file but the implementation contract does not exist in this repo yet. Deploy a reputation contract separately and pass its address to the constructor.

**Fee accounting:** 2% fee is taken from winning payouts (not from bets). Fees accumulate per-token in `collectedFees` and are withdrawn by the owner via `withdrawFees(tokenAddress)`.

## Project layout

- `src/` — contract source files
- `test/` — Forge tests (inherit from `forge-std/Test.sol`)
- `script/` — deployment/interaction scripts (inherit from `forge-std/Script.sol`)
