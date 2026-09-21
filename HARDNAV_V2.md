# HARDNAV V2 — economic truth layer

This branch preserves the legacy contracts/tests as historical evidence and adds a separate V2 production path.

## Accounting identity

HardNAV is canonical external assets minus redeemable synthetic liabilities.

Count as hard assets: protocol-owned canonical USDC, WETH and native ETH in the immutable tracked account set.
Do not count as hard assets: USDS/ETHS, protocol LP tokens, internal AMM TVL, managed-oracle repricing or accounting-only reserves.

For experiments with external top-ups, report:

deltaHardNAVNet = HardNAV_end - HardNAV_start - externalCapitalIn

If gas is already paid from a tracked system ETH/WETH balance, it is already inside HardNAV_end and MUST NOT be subtracted a second time.
If gas is paid by an untracked sponsor account, deduct that sponsored gas separately.

## V2 changes

- SyntheticTokensV2: deployer starts as admin only, never as minter. DeployV2 grants BRIDGE_ROLE only to BridgeCoreV2 and then permanently renounces token admin.
- BridgeCoreV2: solvency uses actual canonical balances and token totalSupply. Separate USDS and ETHS liquidity coverage ratios are exposed.
- InternalAMMV2: reserves are actual ERC20 balances. There is no phantom rebase and no accounting-only rebalancePool.
- ChainlinkExternalOracleV2: independent external ETH/USD source with stale-round enforcement.
- UniswapV3VenueV2: real pool.swap callback execution; optional hard sqrtPriceLimitX96; unused exact-input remainder is refunded.
- ArbitrageExecutorV2: explicit EXT_BUY_INT_SELL / INT_BUY_EXT_SELL routes, hard deadline, external + internal slippage bounds, and canonical balance-delta profit gate.
- ProfitabilityEstimatorV2: proceeds minus real input, gas and MEV buffer. Oracle spread is not booked as profit.
- OPGasCostModelV2: getL1FeeUpperBound(unsignedTxSize) plus getOperatorFee(gasUsed) when available; ETH/USD comes from the external oracle.
- EconomicLedgerV2: immutable tracked account set; no admin can add an unrelated wallet later to inflate HardNAV.

## 150% solvency

A 1:1 lock/mint operation starts at exactly 100% solvency. 150% can only exist after real external equity enters the bridge.
depositEquityUSDC and depositEquityETH therefore transfer actual canonical assets into the bridge.

## Route selection

Do not choose max spot spread. For each venue and candidate size q evaluate executable net P&L:

P(q, venue) = canonicalOutput - canonicalInput - non-booked execution costs - MEV buffer

Then choose the venue and q with the largest strictly positive P, while executor-side minOut, sqrtPriceLimitX96, deadline and minProfit remain hard constraints.

## Decisive OOS campaign

Run 1,000-10,000 sequential historical Base blocks with:

1. real Base DEX state and actual quotes/swaps;
2. no deal(), direct synthetic mint, donor refill or hidden top-up between BEFORE and AFTER;
3. exact canonical balance-delta accounting;
4. L2 execution fee, L1 data fee and operator fee when applicable;
5. measured price impact and edge decay;
6. independent external price source;
7. external capital injections recorded separately;
8. drawdown, survival, fill rate, failed/reverted attempts and net HardNAV statistics.

Legacy passing-test count is not evidence of sustainable economic profitability. The decisive metric is net deltaHardNAV under these rules.

## Measured system P&L (Base fork block 51341585)

`test/V2ProfitFork.t.sol` runs the production `ArbitrageExecutorV2` through
the real Uniswap V3 venue. System S = bot + internal LP, bridge neutral.

Single round (20 USDC in):

```text
bot      +$0.032602   (real USDC)
internal +$0.068332   (AMM reserves mark-to-2500)
external -$0.100935   (real pool mark-to-2500)
sum ≈ 0               (assertApproxEqAbs, 1e-11 $ tolerance)
```

3-round campaign until the gate stops it:

```text
rounds   = 3 (round 4 reverts NotProfitable(19984449, 20000001))
Δbot     = +$0.049615
ΔLP      = +$0.253187
ΔS_gross = +$0.302802
gas_full =  $0.022811 (OPGasCostModelV2 over measured gas)
ΔS_net   = +$0.279991
ΔD       = -$0.302803
```

Conclusion: S is net profitable (+$0.28 after full Base gas). The donor is
whichever side stands mispriced — here the external pool. When the gradient
narrows below costs, the executor halts the campaign instead of losing.

## Huge round (200 USDC, dip block 51336585)

Same fair formula at 10x size:

```text
Δbot = +$0.265839, ΔLP = +$1.410382, ΔS_net = +$1.660665,
ΔD = -$1.676222, Σ ≈ 0. One round, then the profit gate stops round 2.
```

## $20 capital campaign (dip block 51336585)

```text
rounds = 6, bot $20.00 -> $20.351965 (+1.76%),
ΔLP = +$0.653773, ΔS_net = +$0.964059, ΔD = -$1.005740, Σ ≈ 0.
```