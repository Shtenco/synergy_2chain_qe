# Profit Limitations And Next Steps

This file records the hard boundary between what the tests prove and what remains unproven.

## Proven

1. On Base fork block `51341585`, real USDC and WETH token contracts can be used by the bridge/accounting stack.
2. With a donor pool initialized at `40,000,000 USDC / 20,000 WETH`, the system completes 20 native-token mock-donor harvest rounds.
3. In that mock-donor run, the system's measured equity increases by `79.034542387919705` and donor value decreases by the same amount.
4. The bot's real fork-state USDC balance increases by `77.516247 USDC` in the mock-donor native run.
5. A direct real Uniswap V3 external leg now works on fork: `IUniswapV3Pool.swap` against `0x6c561B446416E1A00E8E93E221854d6eA4171372`.
6. In one direct Uniswap V3 round, the system grows by `0.100934947412505000`, the real pool loses the same fair-mark value, and the bot gains `0.039828 USDC`.
7. In 20 direct Uniswap V3 rounds, the system grows by `2.018602825823602500`, the real pool loses the same fair-mark value, and the bot gains `0.491033 USDC`.
8. Under the project's gas model, a 25-round mocked campaign remains net positive by `51.908481412974912268`.

## Not Proven

1. Profit through the current production `ArbitrageExecutor`.
2. Profit after full production gas accounting for the direct Uniswap V3 route.
3. Profit after MEV, private mempool execution, competition, and quote staleness.
4. Sustainable repeated profit after the real pool price and internal AMM price converge.
5. Organic starting capital; the direct test funds actors with Foundry `deal(USDC, ...)`.

## Exact Reason The Donor Loses

The donor is valued at the same fair price as the system: `2,500 USDC/WETH`.

But the donor mock starts at:

```text
40,000,000 USDC / 20,000 WETH = 2,000 USDC/WETH
```

Every trade buys WETH from the donor below the `2,500` fair mark. Therefore, after each trade:

```text
donor receives USDC below fair value of WETH sold
donor loses mark-to-fair value
system receives positive mark-to-fair value
```

This is ordinary cross-venue arbitrage against a stale or mispriced counterparty.

## Required Work To Make This Deployable

1. Replace `ForeignPoolMock` with a real Base DEX integration: Uniswap V3 pool/router or Aerodrome route.
2. Remove `vm.prank(GIANT)` from any profit proof; capital must come from actual swaps, not impersonation.
3. Rewrite `ArbitrageExecutor` so it performs the complete route atomically:
   - external exact-input or exact-output swap,
   - WETH unwrap/wrap,
   - bridge lock/mint with correct `msg.value`,
   - internal AMM swap with slippage limits,
   - bridge burn/unlock,
   - balance-delta profit check,
   - gas-aware minimum profit.
4. Fix executor direction mapping:
   - internal rich: buy external, sell internal,
   - internal cheap: buy internal, sell external.
5. Enforce controller halt/depeg state inside executor.
6. Remove or collateralize accounting-only `rebaseLP`, `batchRebase`, and `rebalancePool`.
7. Revoke deployer `BRIDGE_ROLE` from USDS/ETHS after granting roles to `BridgeCore`.
8. Add real-router fork tests with no donor mock and no impersonated donor funding.

## Test Commands To Reproduce

Native 20-round real token simulation:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --match-contract NativeUsdcHarvest --match-test TwentyRounds -vv
```

Donor conservation:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --match-contract ForeignDonorFork --match-test ExtractFromStaleForeignPool -vv
```

Gas-aware campaign:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --match-contract GasAwareMaxProfit --match-test Campaign25 -vv
```

Direct real Uniswap V3 route:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --match-contract DirectUniswapV3Harvest -vv
```

Full suite:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --summary
```
