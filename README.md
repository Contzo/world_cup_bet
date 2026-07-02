# World Cup On-Chain Betting

A parimutuel prediction market for World Cup outcomes, built with [Foundry](https://book.getfoundry.sh/).

`WorldCupBetting.sol` lets anyone create a market with a set of outcomes; users stake collateral
(native ETH or an ERC20) on an outcome and receive shares priced by a proportional AMM. After the
resolution time, the market's arbitrator resolves it, and winners claim their share of the total
pool minus a 2% platform fee. Open positions can also be traded on a peer-to-peer secondary market,
and each settlement updates the caller's score in `ReputationSystem.sol`.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Setup

```bash
forge install   # pull submodule dependencies
```

## Build & test

```bash
forge build --skip PreditionMarket.sol
forge test  --skip PreditionMarket.sol -vv
```

> `src/PreditionMarket.sol` is an unrelated work-in-progress reference and does not compile;
> `--skip` excludes it. The assessment lives entirely in `WorldCupBetting.sol`.

The suite in `test/WorldCupBetting.t.sol` covers the full lifecycle: market creation and resolution,
net-of-fee payouts and fee withdrawal, timing and access-control reverts, the slippage guard, the
ERC20 path, and the secondary market.
