# Profit Formulas — solved and fork-verified

## 1. Master equation (per-round profit)

For trade size `s` (USD), edge `e` (fraction), full gas `g` (USD),
USDS-side depth `U` (USD), 50/50 constant-product pool, 0.3% fees per side:

```text
profit = s × (e − 0.006 − s/U) − g
```

Terms: `e` = cross-venue spread value, `0.006` = two-side fees,
`s/U` = price impact, `g` = full Base gas (measured ~$0.007/round:
~450k gas L2 + L1 upper bound + operator, via OPGasCostModelV2).

## 2. Pool depth requirement

```text
U  >  s / (e − 0.006 − g/s),   TVL = 2U
```

## 3. ABSOLUTE FLOOR — edge below which NO pool depth helps

The denominator must stay positive:

```text
e_min  =  0.6%  +  g / s
```

Measured `g = $0.007`:

| Trade size | g/s | ABSOLUTE FLOOR e_min | Meaning |
|---|---|---|---|
| $5 | 0.140% | **0.740%** | dip must exceed 0.74% or nothing works |
| $10 | 0.070% | **0.670%** | dip must exceed 0.67% or nothing works |
| $20 | 0.035% | **0.635%** | dip must exceed 0.635% or nothing works |

Smaller size = higher floor (fixed gas eats a larger share).
Below the floor the equation has no solution at any TVL.

## 4. TVL boundary table (dip edge scenarios)

TVL = 2s / (e − 0.006 − g/s). "—" = impossible (below floor).

| Size | e = 0.8% | e = 1.14% (measured dip) | e = 2.0% |
|---|---|---|---|
| $5 | $16,667 | $2,488 | $794 |
| $10 | $15,385 | $4,237 | $1,504 |
| $20 | $24,242 | $7,890 | $2,930 |

Rule of thumb: hold 2x boundary TVL for comfortable margin.

## 5. Optimal trade size (deep pool)

```text
s*  =  U × (e − 0.006) / 2
```

Capital-constrained (s ≤ capital): trade all-in.

## 6. Fork verification log (dip block 51336585, e = 1.14%)

| Config | Predicted bot | Measured bot | System net |
|---|---|---|---|
| U=$50k, s=$20 | +$0.100 | +$0.0326/round (6 rounds) | +$0.964 |
| U=$8k, s=$20 | +$0.051 | +$0.0567 | +$0.156 |
| U=$4k, s=$20 (boundary) | +$0.001 | +$0.0066 | ~0 |
| U=$10/side ($20 TVL), s=$2 | negative | gate refused all 5 attempts, $20.00 intact | 0 |

Tests: `test/V2PoolSizing.t.sol`, `test/V2SmallCap.t.sol`,
`test/V2ProfitFork.t.sol`.

## 9. Micro-trade gas discipline (R = gross / full gas, dip, deep pools)

Rule: R(s) = s·(e−f)/g. Measured (`test_MicroGasPayback2x`):

| Size | Gross | R measured | R predicted | Verdict |
|---|---|---|---|---|
| $5 | +$0.0207 | **2.70x** | 3.1x | ≥2x bar ✅ |
| $2 | +$0.0077 | **1.32x** | 1.26x | net-positive, below bar |
| $1 | +$0.0044 | **0.64x** | 0.63x | gas loss (honest) |
| $0.5 | +$0.0022 | **0.31x** | 0.31x | gas loss (honest) |

Thresholds (dip 1.14%, gas $0.007): R≥2x needs s ≥ ~$3.2;
net-positive needs s ≥ ~$1.6. Operational rule: set executor
minProfit ≥ 2x typical full gas (~$0.014) — the gate then auto-refuses
sub-discipline sizes. All four micros summed: bot +$0.034 total.

## 10. Blueprint B: $500 total system (spike 4.1%, INT direction)

AMM $90/side ($180) + backing buffer $300 + bot $20 = $500.
All inventory via 1:1 locks (solvency 100% by construction).
`test/V2Micro500.t.sol` @ spike block 51314085:

```text
rounds = 1 (round 2 refused: micro-depth decay, gate working)
botD = +$0.028259, oursD = +$0.049221, uniD = -$0.077480, Σ = 0
fee = $0.012902, systemNet = +$0.064578, solvency 10000, dust 0
bot: $20.00 -> $20.028259
```

$500 works iff: fully-backed micro-inventory + spike edge ≥4% +
$2 size. Predicted +$0.014, measured +$0.065 (conservative impact model).

## 7. Unified minimums: POOL-BRIDGE vs BRIDGE-LOCK ($118M mint pool)

Setup: internal MINT pool $118M (59M/23.6k), external real pool ~$121.5M
(measured: 53.06M USDC + 27.39k WETH at dip block), arb capital $20,
dip edge 1.14%. Test: `test/UnifiedBridges.t.sol`.

Full budget equation ($20 size):

```text
s·e > s·(fees) + s²·Σ(1/U) + gas + minProfit,   Σ over conversion venues
```

Bridge-lock: venues = {internal AMM} + GLOBAL solvency rule
liabilities ≤ assets. With pre-minted supply M and backing X:

```text
(X)/(M+X) < 1  for every finite X  →  minimum backing = INFINITY.
```

Measured: $1k backing reverts `Insolvent`, $118M backing reverts
`Insolvent`. A minted pool is UNBOARDABLE on the vault bridge, period.
Compatible config: lock-minted pools only (backing = supply, proven:
V2EqualPools $117M). Bridge-lock minimum ≈ pool TVL itself.

Pool-bridge: no global rule, venues = {amm, poolA, poolB}:

```text
400·(1/U_amm + 1/U_A + 1/U_B) < 0.076  →  U_each > ~$10.5k/side
```

Measured: 12k/12k + 5/5 EXECUTES (net +$0.156), 10k/10k + 2/2 refuses
(0 rounds, capital intact), 1k/0.2 refuses.

| Design | Minimum backing capital | Rule |
|---|---|---|
| BRIDGE-LOCK (minted pool) | ∞ (unboardable) | global solvency vs fungible supply |
| BRIDGE-LOCK (lock-minted) | = pool TVL ($117M) | 1:1 at birth |
| POOL-BRIDGE | internal $8.3k + pools ~$21k ×2 ≈ **$50k** | per-leg impact budget |

Pool-bridge needs ~2000x less backing capital. Trade-off: no solvency
guarantee — LPs bear divergence risk instead of a vault enforcing it.

## 8. Floor proof at $500 TOTAL (all sizes refuse)

System: every venue $80/side (AMM 80/0.032, poolA 80/80, poolB
0.032/0.032) + $20 bot = $500. Best case: spike block (edge ~4.1%).
Bounds 50% loose, so refusal is pure economics.

Equation: profit = s·(e − 0.007 − 3s/80) − 0.012 − minP has NO real roots
(discriminant < 0) for any s — impossible at every size.

Measured (`test_PoolBridge_Floor500_AllRefuse`): sizes $0.5/$2/$5/$20
tried, **0 executions**, bot exactly $20.00, pools untouched.
Minimum minimorum ≈ $750 total at 4%+ edge (≈$0.7 micro-trades);
$500 needs ≥6% edge — never observed in the 24h sample.
Test: `test/UnifiedBridges.t.sol`.
