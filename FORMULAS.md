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
