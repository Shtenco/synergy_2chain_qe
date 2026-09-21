# V2 Walk-Forward Report — trend-symmetric harvest, 30 historical Base blocks

Range: blocks 51297585 → 51341085, step 1500 (~44k blocks ≈ 24h).
Fair mark: fixed 2500 USDC/WETH. Bands: EXT_BUY below 2482, INT_SELL above 2518.
Size: 20 USDC/round. Executor minProfit: $0.02. Internal pool fresh-seeded
FAIR (50k/20) every block — nothing appointed off-market.

Method: one forge process per `--fork-block-number` (the pinned forge build
crashes on `vm.rollFork` across the Isthmus boundary:
"Missing operator fee scalar for isthmus L1 Block"). Each sample deploys a
fresh V2 system, quotes the REAL pool, executes or skips, logs net =
bot delta + internal-LP delta − full Base gas (OPGasCostModelV2).
Funding via deal() per block = independent samples (disclosed).

## Per-block results (block, price, action 0/1/2, net USD)

```text
51297585 2514.15  skip
51299085 2512.88  skip
51300585 2510.33  skip
51302085 2503.30  skip
51303585 2505.18  skip
51305085 2503.33  skip
51306585 2505.28  skip
51308085 2529.67  INT  +0.1695
51309585 2529.67  INT  +0.1695
51311085 2535.68  INT  +0.2173
51312585 2542.04  INT  +0.2678
51314085 2607.12  INT  +0.7851   <- spike block
51315585 2554.98  INT  +0.3707
51317085 2549.93  INT  +0.3306
51318585 2540.42  INT  +0.2550
51320085 2522.13  INT  +0.1096
51321585 2514.27  skip
51323085 2514.28  skip
51324585 2514.29  skip
51326085 2511.06  skip
51327585 2503.06  skip
51329085 2497.13  skip
51330585 2486.10  skip
51332085 2492.67  skip
51333585 2486.07  skip
51335085 2475.39  EXT  +0.1321
51336585 2471.78  EXT  +0.1615
51338085 2471.80  EXT  +0.1613
51339585 2472.55  EXT  +0.1552
51341085 2479.97  EXT  +0.0949
```

## Aggregate

```text
INT executions:  9, all net-positive, subtotal +$2.6751
EXT executions:  5, all net-positive, subtotal +$0.7050
Skips:           16 (price inside bands, correctly ignored)
Failed:          0
TOTAL walk-forward net: +$3.3801 over 30 sampled blocks
Hit rate on executed rounds: 100% (per-sample assertGt(netT, 0) green x14)
```

## Why the earlier runs behaved as they did

- Profitable single-pool run (+$0.28): fair-seeded pool, spread 100% external
  (market 2487 vs our 2500), one direction. Outside donor paid $0.30;
  our LP earned +$0.25, bot +$0.05. Zero self-subsidy.
- Losing symmetric run (−$0.23): BOTH spreads appointed internally
  (pools at 2758 and 2286). Our LPs paid $21.88, bot took $21.70,
  external venue skimmed $0.17 + gas $0.06. Self-subsidy + double tax.
- This walk-forward (+$3.38): fair pools every block, spreads arrive from
  OUTSIDE at different times (rally to 2607, dip to 2471), both directions
  fire, each execution net-positive after full gas. No self-subsidy.

## Reproduce (one block)

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" `
  --fork-block-number 51314085 --no-isolate --match-contract V2WalkForward -vv
```

Test file: `test/V2WalkForward.t.sol`.
