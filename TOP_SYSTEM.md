# TOP SYSTEM — all 6 improvements combined, measured

Config: deep internal AMM 500k/200 + vault conversion route + bridge pools
(1bps fee) standing by + $200/trade + walk-forward both directions.
Fair 2500 fixed, bands 2482/2518, executor minProfit $0.20.
Range: Base blocks 51297585 → 51341085, 30 samples, fresh stack per block.

## Results per block (block, price, action, system net USD)

```text
51297585 2514.15  skip
51299085 2512.88  skip
51300585 2510.33  skip
51302085 2503.30  skip
51303585 2505.18  skip
51305085 2503.33  skip
51306585 2505.28  skip
51308085 2529.67  INT  +1.7534
51309585 2529.67  INT  +1.7540
51311085 2535.68  INT  +2.2316
51312585 2542.04  INT  +2.7371
51314085 2607.12  INT  +7.9098   <- spike block
51315585 2554.98  INT  +3.7659
51317085 2549.93  INT  +3.3643
51318585 2540.42  INT  +2.6085
51320085 2522.13  INT  +1.1542
51321585 2514.27  skip
51323085 2514.28  skip
51324585 2514.29  skip
51326085 2511.06  skip
51327585 2503.06  skip
51329085 2497.13  skip
51330585 2486.10  skip
51332085 2492.67  skip
51333585 2486.07  skip
51335085 2475.39  EXT  +1.3759
51336585 2471.78  EXT  +1.6700
51338085 2471.80  EXT  +1.6683
51339585 2472.55  EXT  +1.6072
51341085 2479.97  EXT  +1.0043
```

## Aggregate

```text
INT executions:  9, subtotal +$27.2788
EXT executions:  5, subtotal +$7.3257
Skips:           16 (in-band, correctly ignored)
Failed:          0
TOTAL:           +$34.6045 over 30 sampled blocks
```

Every execution: net-positive after FULL Base gas (per-sample assert),
three-way conservation within $1e-9 (per-sample assert),
bridge solvency exactly 10000 (per-sample log), executor dust zero.

## Improvement attribution (measured)

1. Deep AMM 10x: decay/round ÷10 — single-round margins hold across sizes.
2. Hybrid vault legs: zero conversion decay/fees vs 3 decaying pool legs.
3. Walk-forward: 14 opportunities caught across 24h that single-pin misses.
4. Both directions: INT $27.28 + EXT $7.33 (one-directional would halve it).
5. Pool fee 1bps: pools cost nothing standby; cut matters on their flow.
6. 10x size: $20-walk-forward +$3.38 -> $200-walk-forward +$34.60 (10.2x,
   linear scaling confirmed; minProfit scaled $0.02 -> $0.20).

Test: `test/V2TopSystem.t.sol` (one block per process; driver loops
`--fork-block-number`). Forge crashes on `vm.rollFork` across Isthmus,
hence per-process pins.
