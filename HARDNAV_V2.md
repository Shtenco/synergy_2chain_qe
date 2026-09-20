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