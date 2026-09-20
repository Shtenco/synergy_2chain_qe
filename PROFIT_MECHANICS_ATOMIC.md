# Profit Mechanics - Atomic Breakdown

This document describes the exact mechanics behind the observed profit in the Base fork tests.

## One-Sentence Summary

The system profits only when it buys ETH/WETH from an external venue below the system's internal fair value, sells the ETH exposure into the internal synthetic AMM, redeems the resulting USDS for real USDC, and the external venue absorbs the mark-to-fair loss.

There are now two tested external-leg implementations:

1. `NativeUsdcHarvest`: real USDC/WETH tokens, but external venue is `ForeignPoolMock` funded from a forked pool address.
2. `DirectUniswapV3Harvest`: real USDC/WETH tokens and direct `IUniswapV3Pool.swap` against the real Base pool `0x6c561B446416E1A00E8E93E221854d6eA4171372`.

## What Is Real In The Native Test

The native test uses real Base token contracts on a pinned fork:

```text
USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 6 decimals
WETH = 0x4200000000000000000000000000000000000006, 18 decimals
```

The bridge detects the real USDC decimal count and normalizes balances:

```text
raw USDC 6-dec amount * 1e12 = internal 18-dec USDS accounting amount
```

Example from `NativeUsdcHarvest.setUp()`:

```text
150,000 USDC raw = 150,000 * 1e6
bridge totalLockedUSDC = 150,000 * 1e18
seeder USDS balance = 150,000 * 1e18
```

## What Is Simulated In The Native Test

The external donor venue is not the real Uniswap V3 pool mechanics.

The test uses Foundry impersonation:

```solidity
vm.prank(GIANT);
IERC20(USDC).transfer(...);
```

where:

```text
GIANT = 0x6c561B446416E1A00E8E93E221854d6eA4171372
```

This means the real fork-state token balances of that address are moved by test cheatcode into test-controlled addresses and then into `ForeignPoolMock`.

Therefore:

```text
Real tokens: YES
Real Uniswap V3 trading path: NO
Real deployable access to donor balances: NO
Simulated stale donor curve: YES
```

## What Is Direct In The Uniswap V3 Test

`DirectUniswapV3Harvest` removes `ForeignPoolMock` from the external leg.

The test asserts pool token ordering:

```text
token0 = WETH
token1 = USDC
```

Then it calls the real pool:

```solidity
IUniswapV3PoolDirect(UNI_POOL).swap(
    address(this),
    false,          // token1 USDC -> token0 WETH
    int256(usdcIn), // exact USDC input
    MAX_SQRT_RATIO_MINUS_ONE,
    bytes("")
);
```

The test contract implements the real pool callback:

```solidity
function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
    require(msg.sender == UNI_POOL, "bad callback sender");
    require(amount0Delta < 0, "must receive WETH");
    require(amount1Delta > 0, "must pay USDC");
    IERC20(USDC).transfer(UNI_POOL, uint256(amount1Delta));
}
```

Therefore the external trade is a real Uniswap V3 pool swap:

```text
Real tokens: YES
Real Uniswap V3 swap: YES
ForeignPoolMock: NO
Pool callback paid in USDC: YES
```

Starting capital in this direct test is assigned by Foundry `deal(USDC, ...)`. That is only funding for test actors; it does not move pool liquidity into a mock and does not simulate the external swap.

## Initial Native-Test Balance Sheet

### Bridge Backing

```text
150,000 real USDC locked into BridgeCore
150,000 USDS minted to seeder
```

### Bot Capital

```text
500 real USDC
```

### Internal Synthetic AMM

```text
500,000 USDS
200 ETHS
Internal price = 500,000 / 200 = 2,500 USDS per ETHS
```

These synthetics are minted directly by the test deployer role, so this is a test-created internal venue.

### External Donor Mock

```text
40,000,000 real USDC
20,000 real WETH
Donor price = 40,000,000 / 20,000 = 2,000 USDC per WETH
```

Thus the test introduces a stale price gap:

```text
internal fair value = 2,500
donor sale price   = 2,000
spread             = 500 per ETH, before fees and price impact
```

## One Round, Atom By Atom

Trade size in native test:

```text
TRADE = 0.008 WETH
```

For the direct Uniswap V3 test, the external leg uses exact USDC input:

```text
USDC_IN = 20 USDC
```

### Step 1 - Quote Gate

The test computes internal pool price:

```text
poolPx = amm.reserveUSDS * 1e6 / amm.reserveETHS
```

For native 6-dec donor reserves, donor price must be scaled as:

```text
forPx = foreignPool.reserveU * 1e18 / foreignPool.reserveE
```

This gives the donor's USDC-per-WETH price in 6-dec units.

Spread is:

```text
spreadBps = (poolPx - forPx) * 10000 / forPx
```

Positive spread means internal ETH is richer than foreign ETH, so the profitable route is:

```text
buy foreign WETH cheap -> sell internal ETHS rich
```

### Step 2 - Buy WETH From Donor

The bot spends exact USDC input `dx` into `ForeignPoolMock.swapUforE(dx)`.

The exact `dx` for `0.008 WETH` output is calculated from constant-product reserves:

```text
dx = (reserveU * 1000 * TRADE) / (997 * (reserveE - TRADE)) + 1
```

This buys real WETH from the mock donor.

Economic effect:

```text
bot USDC decreases
bot WETH increases
donor USDC increases
donor WETH decreases
```

Because donor WETH is sold below the test's fair value, the donor's mark-to-fair value decreases.

### Step 2B - Direct Uniswap V3 Variant

In `DirectUniswapV3Harvest`, the bot/test contract pays `20 USDC` directly to the real Uniswap V3 pool via callback and receives WETH from the pool.

Measured one-round values:

```text
effective execution price = 2487.446485 USDC/WETH
wethOut = 0.008040373978965002 WETH
```

Because the internal fair mark is `2,500 USDC/WETH`, the received WETH has fair value:

```text
0.008040373978965002 * 2500 = 20.100934947412505 USDC
```

The real pool receives only `20 USDC`, so at the test's fair mark the pool loses:

```text
20.000000 - 20.100934947412505 = -0.100934947412505
```

This exactly matches the measured direct one-round pool delta:

```text
realUniPoolDelta = -0.100934947412505
systemEquityDelta = +0.100934947412505
```

### Step 3 - Unwrap WETH

The bot calls real WETH `withdraw(got)`.

Effect:

```text
bot WETH decreases
bot native ETH increases
```

### Step 4 - Lock ETH And Mint ETHS

The bot calls:

```solidity
bridge.lockETHAndMintETHS{value: got}(bot, got);
```

Effect:

```text
bridge ETH reserve increases by got
bot receives got ETHS
bridge totalLockedETH increases
bridge totalMintedETHS increases
```

This does not create net value. It wraps canonical ETH into synthetic ETHS.

### Step 5 - Sell ETHS Into Internal AMM

The bot approves ETHS and calls:

```solidity
amm.swap(got, false, 0);
```

`false` means ETHS -> USDS.

Effect:

```text
bot ETHS decreases
bot USDS increases
AMM ETHS reserve increases
AMM USDS reserve decreases
```

The internal AMM starts at 2,500 USDS/ETHS, so the bot receives USDS at the richer internal price, minus AMM fee and price impact.

### Step 6 - Burn USDS And Unlock Real USDC

The bot calls:

```solidity
bridge.burnUSDSAndUnlockUSDC(bot, usdsOut);
```

For real 6-dec USDC payout:

```text
payoutRaw6 = usdsOut / 1e12
```

Effect:

```text
bot USDS decreases
bot real USDC increases
bridge USDC reserve decreases
bridge totalMintedUSDS decreases
bridge totalLockedUSDC decreases by payoutRaw6 * 1e12
```

### Step 7 - Profit Calculation

Bot profit is actual USDC balance delta:

```text
profit6 = botUSDC_after - botUSDC_before
```

In the 20-round run:

```text
sum(profit6) = 77.516247 USDC
```

## Why System Grows

The system book includes:

```text
bridge USDC balance
seeder USDC balance
bot USDC balance
lp USDC balance
bot WETH at fair price
bridge ETH and bot ETH at fair price
AMM USDS reserve
AMM ETHS reserve at fair price
minus total USDS supply
minus total ETHS supply at fair price
```

The system grows because it now holds more fair-valued ETH exposure and extracted USDC than it paid to the donor at the stale donor price.

In the 20-round native run:

```text
systemEquityDelta = +79.034542387919705
```

## Why Donor Loses

The donor book is:

```text
donorValue = donorUSDC * 1e12 + donorWETH * fairPrice
```

The donor starts with WETH implicitly valued by the test at 2,500 but sells it along a pool curve initialized at 2,000.

In the 20-round native run:

```text
donorDelta = -79.034542387919705
```

This exactly mirrors the system growth:

```text
systemEquityDelta + donorDelta = 0
```

within integer rounding tolerance.

## Where The Extra 1.518295 Comes From

Native 20-round run:

```text
bot USDC profit     = 77.516247
system equity gain  = 79.034542387919705
difference          = 1.518295387919705
```

The difference is value retained inside the internal AMM/LP due to swap fees and reserve movement. It is system value, but not bot cash.

## Gas-Aware Interpretation

The gas-aware campaign shows the route can remain positive under the project's Base gas model:

```text
grossBotCash       = 52.041764522648619415
harvestGas         = 0.127860278260331925
settlementGas      = 0.005422831413375222
netAfterAllGas     = 51.908481412974912268
```

However, that test uses mocked traded assets and a mock donor venue. It is a gas sensitivity model, not a proof of real Base router profitability.

## Critical Production Caveat

The observed profitable route is implemented manually in test helper `_execRound`, not by the production `ArbitrageExecutor`.

The adversarial test `ModelAuditTruth.test_QuotedCycleAProfitIsNotExecutable` proves:

```text
executor.isCycleAProfitable(...) returns true
executor.executeCycleA(...) reverts before realizing profit
totalCyclesExecuted remains 0
totalProfitGenerated remains 0
```

Reason:

```text
ArbitrageExecutor calls bridge.lockETHAndMintETHS(address(this), ethVolume)
but sends no msg.value.
BridgeCore requires msg.value == ethVolume.
```

Therefore, current production executor does not yet realize the tested profit path.

## Final Profit Statement

Under the exact pinned-fork test conditions:

```text
The system grows: YES
The donor loses: YES
The value transfer is conserved: YES
Native Base USDC/WETH contracts are used: YES
The donor address is a real fork-state Base pool address: YES
The direct test's external venue is real Uniswap V3: YES
The mock-donor test's external venue is real Uniswap V3: NO
The route is executed by production ArbitrageExecutor: NO
The route is profitable after the project's gas model in mocked gas-aware campaign: YES
```
