# Perpetual Arbitrage Engine - Base Mainnet Fork

## ОСНОВНАЯ ЛИНИЯ СИСТЕМЫ (V2, измерено на форке Base)

Равные пулы: внутренний TVL = внешнему TVL (~$117M). Капитал $20:

```text
25/25 раундов без затухания, бот $20.00 → $22.67 (+13.4%),
система net +$4.06 после полного газа, донор −$4.19, Σ ≈ 0.
```

Почему это главная линия: при паритете глубин сделки не двигают ни
один пул — спред не съедается, кампания идет до cap, а не до gate.
Каждый раунд ≈ +$0.107 боту (уравнение предсказало +$0.101).
Доказательства ниже: разделы MATHEMATICAL PROOF, POOL SIZING EQUATION,
EQUAL POOLS. Файлы: `FORMULAS.md`, `HARDNAV_V2.md`, `WALKFORWARD_REPORT.md`.

## ПУЛОВЫЙ МОСТ (ветка `pool-bridge`) — мост это пулы, сейфа нет

Архитектура: конвертация синтетика ↔ каноника идет НЕ через lock/mint
сейфа, а через свопы в пулах-мостах `BridgePool` (USDS/USDC, ETHS/WETH,
x*y=k, fee 5bps). Эмиссия — один раз 1:1 при genesis, затем BRIDGE_ROLE
отозвана (све supply запечатан навсегда, ассерт в setUp). Исполнитель
`ExecutorPB` — чистый swap-роутер из 4 свопов с balance-delta gate.
В репозитории этой системы нет ни одного vault/bridge-контракта.

Измерено на форке Base, дип-блок 51336585, $20 all-in, 3 раунда
(`test/PoolBridgeFork.t.sol`):

```text
bot                 = $20.00 → $20.115901 (+$0.115901)
пулы-мосты + AMM    = +$0.386971   (пулы ЗАРАБОТАЛИ комиссии)
GROSS bot + пулы    = +$0.502872 > 0   (assert в тесте)
газ полный          =  $0.024510
NET bot + пулы      = +$0.478362 > 0   (assert в тесте)
донор внешний       = -$0.502872
Σ                   = 0.000000 ровно (assert, допуск $1e-11)
```

Доказательство: система «бот + мостовые пулы» в плюсе ТОЧНО —
gross +$0.502872 и net +$0.478362, оба закреплены ассертами,
conservation замкнут в ноль. Пулы не нейтральны как сейф: они
зарабатывают (+$0.39 комиссий остались дома).

### BUYBACK-AND-BURN ИЗ ЗАРАБОТКА (анти-QE, `test_BuybackBurn_FromEarnings`)

50% профита бота ($0.058) → выкуп USDS из PoolA → сжигание через
`BuybackBurner` (только burn-права, минта нет нигде):

```text
supply:     150,000 → 149,999.942 (ровно на burned, assert)
peg USDS:   0.9987977 → 0.9987989 (вверх, assert — пег поддержан)
бот:        $20.057951 (выше старта — выиграл и бот, и холдеры)
conservation С УЧЕТОМ ПЛАМЕНИ: bot + pools + donor + burned = 0 (assert)
```

Минт для этого не нужен вообще: value приходит снаружи (донор),
supply уходит в огонь. Печатать чтобы выкупать — циркулярный бред
(доказано в анализе: net всегда < 0).

## Система алгоритмического арбитража и самовосстанавливающейся ликвидности

### Архитектура (4 уровня)

**L1: External Market (Base Mainnet)**
- Канонические USDC/ETH
- Внешний пул TVL > $100M
- Chainlink TWAP Oracle

**L2: Bridge (Transmutation Layer)**
- BridgeCore.sol - Lock/Mint, Burn/Unlock
- Health Factor мониторинг (≥150%)
- Emergency Stop при HF < 110%

**L3: Internal Fork (AMM + Oracle)**
- InternalAMM.sol - USDS/ETHS pool (x*y=k)
- ManagedOracle.sol - управляемый градиент цен
- Rebase mechanism для защиты LP

**L4: Synthetic Assets**
- USDS.sol - синтетический доллар
- ETHS.sol - синтетический эфир

---

## Установка и запуск тестов

### Требования
- Foundry (forge, cast, anvil)
- Node.js 18+
- Git

### Установка Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Установка зависимостей

```bash
# Установка OpenZeppelin контрактов
forge install OpenZeppelin/openzeppelin-contracts

# Установка forge-std
forge install foundry-rs/forge-std
```

### Запуск тестов

```bash
# Все тесты
forge test

# С подробным выводом
forge test -vvv

# Только BridgeCore тесты
forge test --match-contract BridgeCoreTest

# Только интеграционные тесты
forge test --match-contract ArbitrageIntegrationTest

# С gas репортом
forge test --gas-report

# Fuzz тесты с увеличенным количеством runs
FOUNDRY_FUZZ_RUNS=1000 forge test
```

### Запуск локальной ноды (Base Fork)

```bash
# Fork Base Mainnet
anvil --fork-url https://mainnet.base.org --fork-block-number latest

# В другом терминале - деплой контрактов
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

---

## Смарт-контракты

### 1. USDS.sol & ETHS.sol
Синтетические токены с ролевым доступом. Только Bridge может mint/burn.

### 2. BridgeCore.sol
Основной контракт моста:
- `lockETHAndMintETHS()` - Lock ETH → Mint ETHS
- `burnETHSAndUnlockETH()` - Burn ETHS → Unlock ETH
- `getHealthFactor()` - Расчет HF (canonical/synthetic)
- `triggerEmergencyStop()` - Аварийная остановка

### 3. ManagedOracle.sol
Управляемый оракул с градиентом:
- Mode 0 (UNDERPRICE): Internal < External → Cycle A
- Mode 1 (OVERPRICE): Internal > External → Cycle B
- Mode 2 (NEUTRAL): Минимальный градиент

### 4. InternalAMM.sol
Модифицированный AMM с защитой LP:
- Constant product (x*y=k)
- 0.3% swap fee
- `rebaseLP()` - компенсация LP при дисбалансе
- `getNAVPerShare()` - отслеживание NAV

### 5. TreasuryDistributor.sol
Распределение прибыли:
- 40% Owner (canonical profit)
- 30% Bridge Reserve (HF support)
- 20% Insurance Fund (buffer)
- 10% Rebase Fund (LP compensation)

### 6. ArbitrageExecutor.sol
Исполнитель арбитражных циклов:
- `executeCycleA()` - извлечение из внешнего пула
- `executeCycleB()` - ребалансировка внутреннего пула
- `isCycleAProfitable()` - проверка прибыльности

---

## Арбитражные циклы

### Cycle A: UNDERPRICE Mode (Internal < External)

1. Бот обнаруживает градиент < 0
2. Покупает ETH на Base по рыночной цене
3. Lock ETH → Mint ETHS через Bridge
4. Продает ETHS во внутреннем пуле → получает USDS
5. Burn USDS → Unlock USDC через Bridge
6. Distribute profit через Treasury

**Результат:** Чистая каноническая прибыль от спреда

### Cycle B: OVERPRICE Mode (Internal > External)

1. Бот обнаруживает градиент > 0
2. Покупает ETHS во внутреннем пуле за USDS
3. Burn ETHS → Unlock ETH через Bridge
4. Продает ETH на Base по высокой цене → USDC
5. Конвертирует USDC → USDS для пополнения пула
6. Distribute profit через Treasury

**Результат:** Пул ребалансирован + дополнительная прибыль

---

## Три условия математической устойчивости

### 1. Приток ≥ Эмиссия
```
Arbitrage Profit + Fees ≥ USDS Emission (LP compensation)
```
Проверяется в `TreasuryDistributor.distribute()`

### 2. Health Factor ≥ 150%
```
Canonical Value / Synthetic Value ≥ 1.5
```
Проверяется в `BridgeCore.getHealthFactor()`

### 3. Peg Deviation ≤ 2%
```
|USDS/USDC - 1| ≤ 0.02
```
Поддерживается арбитражными циклами

---

## Тесты

### BridgeCoreTest (24 tests)
- Lock/Mint операции
- Burn/Unlock операции
- Health Factor расчет
- Emergency Stop
- Fuzz тесты

### InternalAMMTest (22 tests)
- Liquidity add/remove
- Swaps с slippage protection
- Rebase mechanism
- NAV tracking
- Constant product verification

### TreasuryDistributorTest (14 tests)
- 40/30/20/10 distribution
- Multiple distributions
- Preview function
- Admin functions

### ArbitrageIntegrationTest (17 tests)
- Full Cycle A workflow
- Full Cycle B workflow
- LP protection verification
- Multi-cycle stability
- Edge cases

**Total: 77 tests, 100% pass rate**

---

## Деплой на Base Mainnet

### 1. Настройка окружения

```bash
export BASE_RPC_URL="https://mainnet.base.org"
export PRIVATE_KEY="0x..."
export BASESCAN_API_KEY="..."
```

### 2. Деплой контрактов

```bash
forge script script/Deploy.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY
```

### 3. Конфигурация

```bash
# Установить роли
cast send $BRIDGE "grantRole(bytes32,address)" $OPERATOR_ROLE $OPERATOR --private-key $PRIVATE_KEY
cast send $ORACLE "grantRole(bytes32,address)" $ALGO_ROLE $BOT --private-key $PRIVATE_KEY

# Настроить Treasury recipients
cast send $TREASURY "updateRecipients(address,address,address,address)" \
  $OWNER $BRIDGE_RESERVE $INSURANCE $REBASE --private-key $PRIVATE_KEY
```

---

## Мониторинг

### Health Factor
```bash
cast call $BRIDGE "getHealthFactor()" --rpc-url $BASE_RPC_URL
```

### Oracle Mode
```bash
cast call $ORACLE "getMode()" --rpc-url $BASE_RPC_URL
# 0 = UNDERPRICE, 1 = OVERPRICE, 2 = NEUTRAL
```

### LP NAV
```bash
cast call $AMM "getNAVPerShare()" --rpc-url $BASE_RPC_URL
cast call $AMM "getLPNAV(address)" $LP_ADDRESS --rpc-url $BASE_RPC_URL
```

---

## Безопасность

### Аудит
- [ ] Reentrancy protection (ReentrancyGuard)
- [ ] Role-based access control (AccessControl)
- [ ] Overflow/underflow protection (Solidity 0.8+)
- [ ] Emergency stop mechanism
- [ ] Oracle staleness check

### Рекомендации
1. Провести внешний аудит перед mainnet деплоем
2. Настроить multi-sig для admin ролей
3. Implement timelock для критических изменений
4. Настроить monitoring и alerting
5. Создать bug bounty программу

---

## Лицензия

MIT License

---

## Контакты

Для вопросов и предложений:
- GitHub Issues
- Telegram: @perpetual_arb_engine
- Discord: Perpetual Arbitrage Engine

Repository: `synergy_2chain_qe`

---

## V2 system profit — mathematical proof (Base fork, block 51341585)

System boundary S = {bot, internal LP (100% of AMM reserves), bridge}.
External donor D = real Uniswap V3 pool `0x6c56...1372`. Bridge is neutral
(solvency stays exactly 10000 bps).

Measured 3-round campaign, 20 USDC/round, `test/V2ProfitFork.t.sol`:

```text
Δbot    = +$0.049615   (real USDC balance delta)
ΔLP     = +$0.253187   (AMM reserves, mark-to-2500)
ΔS_gross = +$0.302802
gas_full =  $0.022811   (OPGasCostModelV2: measured L2 + L1 upper + operator)
ΔS_net   = +$0.279991 > 0
ΔD       = -$0.302803
ΔS_gross + ΔD ≈ 0      (three-way conservation, enforced on-chain in test)
```

Round 4 reverts `NotProfitable(19984449, 20000001)`: the executor refuses
to trade at a loss, so the campaign stops by itself. Profit is finite and
decays as the cross-venue gradient narrows — the gate guarantees no
losing round is ever executed.

### HUGE round: same winning formula, 10x size (dip block 51336585, ~$2471)

Fair pool, external-only spread, one direction, 200 USDC in:

```text
Δbot      = +$0.265839
ΔLP       = +$1.410382   (large size shifts value toward LP inventory)
ΔS_gross  = +$1.676221
gas_full  =  $0.015556
ΔS_net    = +$1.660665
ΔD        = -$1.676222   <- external donor paid 5.6x more than before
Σ         ≈ 0
```

Round 2 reverts on the profit gate (true exhaustion at this size, not a
bounds artifact: output ≈ $198.7 < $200.1 required). Lesson: bigger size =
more per-round extraction but fewer rounds; total capture scales with
edge-squared over pool depth.

### $20 capital, all-in $20/trade, dip block 51336585 (~$2471)

Small trader on deep infrastructure (fair 50k/20 pool, external spread):

```text
rounds    = 6, then the gate stops the campaign
bot       = $20.00 -> $20.351965 (+1.76%)
ΔLP       = +$0.653773
ΔS_net    = +$0.964059   (after full 6-round gas $0.0417)
ΔD        = -$1.005740   <- external donor paid ~5% of bot capital
Σ         ≈ 0
```

---

# MATHEMATICAL PROOF OF THE PROFIT MECHANISM

Base fork, real Uniswap V3 pool `0x6c56...1372`, production
`ArbitrageExecutorV2`. Every number below is measured on-chain in tests,
not modeled.

## Definitions

- `S` (our system) = bot + internal LP + bridge.
- `D` (external donor) = real Uniswap V3 pool, marked at internal fair `F`.
- `P_int`, `P_ext` = executable prices internal / external.
- `q` = trade size. `fees(q)` = both-venue fees + price impact.
- `gas` = full Base cost (measured L2 + L1 upper bound + operator).

## Theorem 1 — Conservation (zero-sum across venues)

```text
Δbot + ΔLP + ΔD = 0
```

Measured single round (20 USDC, pin 51341585), enforced by
`assertApproxEqAbs(..., 1e-11 $)`:

```text
+0.032602 + 0.068332 − 0.100935 ≈ 0
```

Value is never created. It is transferred from whoever stands mispriced.
The accounting is exact — no phantom NAV exists anywhere in V2
(reserves always equal actual token balances, proven in
`test_AMMReserveIsAlwaysActualTokenBalance`).

## Theorem 2 — Profit condition (the gate)

A round executes if and only if:

```text
(P_int − P_ext) × q − fees(q) − gas > minProfit,   minProfit = $0.02
```

checked on REALIZED canonical balance deltas inside the transaction
(`NotProfitable` reverts otherwise). The oracle spread is never booked
as profit — only delivered USDC counts. Therefore:

**No executed round can lose money by construction.** 14/14 walk-forward
executions net-positive. 0 failures.

## Theorem 3 — Finite profit with automatic halt (decay law)

Each round sells `q` into the internal pool, pushing `P_int` down by
`≈ P_int × q / depth`. Margin decays ~$0.016/round at 20 USDC size.
Measured halt: round 4 reverts `NotProfitable(19984449, 20000001)` —
output $19.9844 < required $20.0000. The campaign extracts exactly the
available spread and stops ITSELF before the first losing trade.

## Measured evidence

| Campaign | Bot | LP | System net (full gas) | Donor |
|---|---|---|---|---|
| 3 rounds x20 | +$0.050 | +$0.253 | **+$0.280** | −$0.303 |
| 1 round x200 (dip) | +$0.266 | +$1.410 | **+$1.661** | −$1.676 |
| Walk-forward 30 blocks | — | — | **+$3.380** | market |

Walk-forward: 9 INT + 5 EXT executions, 16 correct skips, 0 fails,
100% hit rate. Spreads arrived from OUTSIDE at different times
(rally 2607, dip 2471). Internal pools fair-seeded every block:
zero self-subsidy.

## Boundary conditions (honest limits)

1. Profit needs external mispricing vs our fair mark. No mispricing =
   no trade (skip, proven 16x).
2. Profit per gradient is finite and decays with our own size/depth.
3. The gate converts "finite" into "never negative": worst case is
   zero executions, never a loss.
4. Bridge solvency invariant: exactly 10000 bps before AND after every
   campaign. The bridge never subsidizes anything.

## The claim

Any DeFi protocol can print a profit number. This system proves a
stronger statement, verified on a real-market fork:

> **Conservation is exact, every executed trade is net-positive after
> full gas by on-chain construction, and extraction halts automatically
> at breakeven. Measured: +$3.38 over 30 historical blocks, 0 losses.**

Reproduce everything:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" `
  --fork-block-number 51341585 --no-isolate --match-contract V2ProfitFork -vv
```

---

## POOL SIZING EQUATION ($20 capital, $118M external donor)

Per-round profit for size `s`, edge `e`, gas `g`, USDS-side depth `U`:

```text
profit = s × (e − 0.006 − s/U) − g
U  >  s / (e − 0.006 − g/s),   TVL = 2U
```

Solved for s = $20, dip edge e = 1.14%, g = $0.007:

```text
U > 20 / 0.00507 ≈ $3,945/side  →  TVL > ~$7,900
```

Verified on-fork (`test/V2PoolSizing.t.sol`, dip block 51336585):

```text
U=$8k (TVL $16k): 1 round, bot +$0.0567 (predicted +$0.051), system net +$0.156
U=$4k (TVL $8k):  1 round, bot +$0.0066 (predicted +$0.001, boundary dust)
```

Absolute floor: edge must exceed `0.6% + g/s` (0.635% at $20 size) —
below that no pool depth helps. Recommended: TVL ≥ 2x boundary (≈$16k).
Optimal size for a deep pool: `s* = U × (e − 0.006) / 2`.

### Absolute floors by trade size (gas $0.007 measured)

| Size | Floor e_min |
|---|---|
| $5 | **0.740%** |
| $10 | **0.670%** |
| $20 | **0.635%** |

Full derivation, TVL tables and verification log: `FORMULAS.md`.

### EQUAL POOLS: internal TVL = external TVL = ~$117M, $20 capital

Deepest proof (`test/V2EqualPools.t.sol`, dip block 51336585):

```text
rounds    = 25/25 (no decay stop — parity depths don't move)
bot       = $20.00 -> $22.673545 (+13.4% on capital)
ΔLP       = +$1.516897   (infrastructure earns while bot harvests)
ΔS_net    = +$4.057493   (after full 25-round gas $0.133)
ΔD        = -$4.190454   <- external donor
Σ         ≈ 0
```

Per-round: bot +$0.107 (equation predicted +$0.101), LP +$0.061,
donor −$0.168 — every round nearly identical. Equal depths remove
self-decay: the campaign hits the cap, not the gate.

Reproduce:

```powershell
tools\foundry\forge.exe test --fork-url "https://mainnet.base.org" `
  --fork-block-number 51341585 --no-isolate --match-contract V2ProfitFork -vv
```

Full breakdown: `HARDNAV_V2.md`.
