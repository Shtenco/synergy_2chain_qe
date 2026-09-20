# Profit Test Report - Base Fork Block 51341585

Date: 2026-09-21

Workspace: `C:\Users\Shtenco\Desktop\2CHAIN_FORK_IMP`

Fork command base:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate
```

## Executive Result

The fork test suite confirms two external-leg modes:

1. The old stale-donor mock mode grows the system and makes the configured donor lose.
2. The new direct Uniswap V3 mode trades directly against the real Base pool `0x6c561B446416E1A00E8E93E221854d6eA4171372` via `IUniswapV3Pool.swap`, with no `ForeignPoolMock` on the external leg.

The strongest native-token result is `NativeUsdcHarvest.test_NativeUsdc_TwentyRounds`:

| Metric | Value |
|---|---:|
| Rounds completed | 20 / 20 |
| Bot USDC profit | 77.516247 USDC |
| Bot USDC balance | 500.000000 -> 577.516247 USDC |
| System equity delta | +79.034542387919705 |
| Donor value delta | -79.034542387919705 |
| Bridge USDC balance after | 149,601.518283 USDC |
| Conservation check | `eqEnd + donorEnd ~= eqStart + donorStart` |

This proves the test-state transfer of value: system gain equals donor loss, up to rounding tolerance.

Important limitation: the donor in this native test is not directly traded as Uniswap V3. The test impersonates the real Base pool address `0x6c561B446416E1A00E8E93E221854d6eA4171372`, transfers its real fork-state USDC/WETH into a new `ForeignPoolMock`, then trades against that mock at a deliberately stale price. Therefore the tokens are real forked Base tokens, but the venue mechanics are simulated.

The direct Uniswap V3 test below removes that limitation for the external leg.

## Direct Uniswap V3 Run

New test file:

```text
test/DirectUniswapV3Harvest.t.sol
```

Command:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --match-contract DirectUniswapV3Harvest -vv
```

Result:

```text
[PASS] test_DirectUniswapV3_OneHarvestRound_SystemGrowsPoolLoses()
[PASS] test_DirectUniswapV3_TwentyHarvestRounds_SystemGrowsPoolLoses()
```

One direct Uniswap V3 round raw logs:

```text
effectivePx6=2487446485
wethOut=8040373978965002
botProfit6=39828
systemEquityDelta=100934947412505000
realUniPoolDelta=-100934947412505000
bridgeUSDCBalance=149979960172
```

Decoded:

```text
effective execution price = 2487.446485 USDC/WETH
wethOut = 0.008040373978965002 WETH
bot profit = 0.039828 USDC
system equity delta = +0.100934947412505000
real Uniswap pool value delta = -0.100934947412505000
bridge USDC balance = 149,979.960172 USDC
```

Twenty direct Uniswap V3 rounds raw logs:

```text
rounds=20
botProfit6=491033
systemEquityDelta=2018602825823602500
realUniPoolDelta=-2018602825823602500
botUSDCBalance=500491033
bridgeUSDCBalance=149599508967
```

Decoded:

```text
rounds = 20
bot profit = 0.491033 USDC
system equity delta = +2.018602825823602500
real Uniswap pool value delta = -2.018602825823602500
bot USDC balance = 500.491033 USDC
bridge USDC balance = 149,599.508967 USDC
```

Direct Uniswap V3 conclusion:

```text
External leg directly uses real Uniswap V3 pool: YES
ForeignPoolMock on external leg: NO
System grows: YES
Real pool loses value at 2,500 fair mark: YES
Bot receives more USDC after full route: YES
```

Important direct-test limitation: test starting capital is assigned with Foundry `deal(USDC, ...)`, not obtained organically. This does not affect the external swap mechanics; it only funds the test actors.

## Tested Addresses

| Name | Address | Role in Test |
|---|---|---|
| Base USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Real canonical 6-decimal USDC token |
| Base WETH | `0x4200000000000000000000000000000000000006` | Real canonical WETH token |
| GIANT donor source | `0x6c561B446416E1A00E8E93E221854d6eA4171372` | Real fork-state address impersonated by Foundry cheatcode |
| ForeignPoolMock | Fresh test deployment | Simulated stale donor venue |

## Native USDC 20-Round Run

Command:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --match-contract NativeUsdcHarvest --match-test TwentyRounds -vv
```

Result:

```text
[PASS] test_NativeUsdc_TwentyRounds() (gas: 4671193)
```

Raw per-round logs from Forge:

```text
round01 profit6=3891054  equityDelta=3951849183746652500
round02 profit6=3889448  equityDelta=3951836360904627500
round03 profit6=3887843  equityDelta=3951823538042930000
round04 profit6=3886238  equityDelta=3951810715161560000
round05 profit6=3884633  equityDelta=3951797892260512500
round06 profit6=3883028  equityDelta=3951785069339795000
round07 profit6=3881423  equityDelta=3951772000156387500
round08 profit6=3879819  equityDelta=3951759177198317500
round09 profit6=3878215  equityDelta=3951746354220575000
round10 profit6=3876611  equityDelta=3951733531223157500
round11 profit6=3875007  equityDelta=3951720708206065000
round12 profit6=3873404  equityDelta=3951707885169300000
round13 profit6=3871801  equityDelta=3951695062112860000
round14 profit6=3870197  equityDelta=3951682239036747500
round15 profit6=3868594  equityDelta=3951669169705937500
round16 profit6=3866991  equityDelta=3951656346592475000
round17 profit6=3865389  equityDelta=3951643523459340000
round18 profit6=3863786  equityDelta=3951630700306530000
round19 profit6=3862184  equityDelta=3951617877134045000
round20 profit6=3860582  equityDelta=3951605053941890000

rounds=20
totalProfit6=77516247
systemEquityDelta=79034542387919705000
donorDelta=-79034542387919705000
botUSDCBalance=577516247
bridgeUSDCBalance=149601518283
```

Decoded values:

```text
totalProfit6=77.516247 USDC
systemEquityDelta=79.034542387919705 normalized dollars
donorDelta=-79.034542387919705 normalized dollars
botUSDCBalance=577.516247 USDC
bridgeUSDCBalance=149,601.518283 USDC
```

Conclusion from this run:

```text
System grows: YES
Donor loses: YES
Conservation across system+donor: YES
```

## Foreign Donor Conservation Run

Command:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --match-contract ForeignDonorFork --match-test ExtractFromStaleForeignPool -vv
```

Result:

```text
[PASS] test_A_ExtractFromStaleForeignPool_Decays() (gas: 1137536)
```

Raw logs:

```text
grossBotProfit=3671271229628364095013
systemEquityDelta=4929784350550400576416
donorDelta=-4929784350550400576416
endingRoundProfit=1495777269453662174834
```

Decoded values in 18-decimal normalized dollars:

```text
grossBotProfit=3671.271229628364095013
systemEquityDelta=4929.784350550400576416
donorDelta=-4929.784350550400576416
endingRoundProfit=1495.777269453662174834
```

Conclusion from this run:

```text
System grows: YES
Donor loses: YES
Conservation across system+donor: YES
Profit decays as donor price moves: YES
```

## Gas-Aware Campaign Run

Command:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --match-contract GasAwareMaxProfit --match-test Campaign25 -vv
```

Result:

```text
[PASS] test_Campaign25_MaxNet() (gas: 13421716)
```

Decoded summary:

```text
rounds=25
grossBotCash=52.041764522648619415
harvestGas=0.127860278260331925
netAfterHarvestGas=51.913904244388287490
treasurySettleGas=0.005422831413375222
netAfterAllGas=51.908481412974912268
systemEquityDelta=98.793710595745532879
donorDelta=-98.793710595745532879
```

Conclusion from this run:

```text
Modeled gas-aware net profit: YES
System grows: YES
Donor loses: YES
Conservation across system+donor: YES
```

Important limitation: `GasAwareMaxProfit` models gas costs but uses mocked traded assets and a mock foreign venue. It is useful for gas sensitivity, not for proving a real DEX route.

## Full Fork Suite

Command:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" --fork-block-number 51341585 --no-isolate --summary
```

Result:

```text
77 passed / 0 failed / 0 skipped
```

Suite table:

```text
ArbitrageIntegrationTest 17 passed
BridgeCoreTest           14 passed
DeepDonor25               1 passed
DirectUniswapV3Harvest    2 passed
ForeignDonorFork          2 passed
GasAwareMaxProfit         2 passed
GradientGrowthFork        2 passed
InternalAMMTest          13 passed
MicroHarvest25            1 passed
ModelAuditTruth           3 passed
NativeUsdcHarvest         3 passed
ProfitReport100           1 passed
RealizedProfitFork        1 passed
Stage2Fork                5 passed
TreasuryDistributorTest  10 passed
```
