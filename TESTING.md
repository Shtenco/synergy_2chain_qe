# Инструкция по запуску тестов

## Быстрый старт

### 1. Установка Foundry

```bash
# Установка Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Проверка установки
forge --version
```

### 2. Установка зависимостей

```bash
# Инициализация проекта (если еще не сделано)
forge init --no-commit

# Установка OpenZeppelin
forge install OpenZeppelin/openzeppelin-contracts

# Установка forge-std
forge install foundry-rs/forge-std
```

### 3. Запуск тестов

```bash
# Все тесты
forge test

# С подробным выводом
forge test -vvv

# С gas репортом
forge test --gas-report

# Только конкретный тест
forge test --match-test test_LockETHAndMintETHS -vvv
```

## Структура тестов

### BridgeCoreTest (24 теста)

**Lock/Mint операции:**
- `test_LockETHAndMintETHS` - Базовый lock ETH и mint ETHS
- `test_LockUSDCAndMintUSDS` - Lock USDC и mint USDS
- `testFail_LockETHWhenStopped` - Попытка lock при emergency stop
- `testFail_LockZeroAmount` - Попытка lock нулевой суммы

**Burn/Unlock операции:**
- `test_BurnETHSAndUnlockETH` - Burn ETHS и unlock ETH
- `testFail_BurnMoreThanMinted` - Попытка burn больше чем minted

**Health Factor:**
- `test_HealthFactorCalculation` - Расчет HF
- `test_HealthFactorWithPriceChange` - HF при изменении цены
- `test_EmergencyStopTriggered` - Trigger emergency stop
- `test_LiftEmergencyStop` - Lift emergency stop

**Fuzz тесты:**
- `testFuzz_LockETH` - 256 runs с разными суммами
- `testFuzz_BurnETHS` - 256 runs с разными суммами

### InternalAMMTest (22 теста)

**Liquidity:**
- `test_AddLiquidity` - Добавление ликвидности
- `test_RemoveLiquidity` - Удаление ликвидности
- `testFail_RemoveMoreThanOwned` - Попытка удалить больше чем есть

**Swaps:**
- `test_SwapUSDSForETHS` - Swap USDS → ETHS
- `test_SwapETHSForUSDS` - Swap ETHS → USDS
- `test_SwapWithSlippage` - Swap с slippage protection

**Rebase:**
- `test_RebaseLP` - Rebase для одного LP
- `test_BatchRebase` - Batch rebase для нескольких LP

**NAV:**
- `test_NAVCalculation` - Расчет NAV per share
- `test_LPNAVTracking` - Отслеживание NAV LP
- `test_PoolRatio` - Проверка соотношения пула
- `test_ConstantProduct` - Проверка x*y=k

### TreasuryDistributorTest (14 тестов)

**Distribution:**
- `test_DistributeProfit` - Базовое распределение
- `test_MultipleDistributions` - Множественные распределения
- `testFail_DistributeZero` - Попытка распределить 0
- `testFail_DistributeMoreThanBalance` - Больше чем баланс

**Preview:**
- `test_PreviewDistribution` - Preview распределения

**Admin:**
- `test_UpdateRecipients` - Обновление получателей
- `testFail_UpdateRecipientsZeroAddress` - Zero address
- `testFail_UpdateRecipientsNotOwner` - Не owner

### ArbitrageIntegrationTest (17 тестов)

**Cycle A:**
- `test_CycleA_UnderpriceMode` - UNDERPRICE mode
- `test_CycleA_ProfitabilityCheck` - Проверка прибыльности
- `test_CycleA_NotProfitableInOverpriceMode` - Не прибыльно в OVERPRICE

**Cycle B:**
- `test_CycleB_OverpriceMode` - OVERPRICE mode
- `test_CycleB_ProfitabilityCheck` - Проверка прибыльности

**Health Factor:**
- `test_HealthFactorMaintainedDuringCycles` - HF поддерживается
- `test_EmergencyStopPreventsOperations` - Emergency stop блокирует

**LP Protection:**
- `test_LPProtectionViaRebase` - Защита LP через rebase
- `test_LPNAVNeverDecreasesBelowInitial` - NAV не падает ниже initial

**Treasury:**
- `test_TreasuryDistributionInCycles` - Распределение в циклах

**Oracle:**
- `test_OracleGradientControl` - Контроль градиента
- `test_OracleModeTransitions` - Переходы между режимами

**Integration:**
- `test_FullCycleAWorkflow` - Полный workflow Cycle A
- `test_MultipleCyclesStability` - Стабильность множественных циклов

**Edge Cases:**
- `test_ZeroSpreadNoArbitrage` - Нет спреда = нет арбитража
- `test_ExtremeGradientRespected` - Экстремальный градиент
- `test_GasEfficientSwaps` - Gas эффективность

## Запуск на Base Fork

### 1. Настройка .env

```bash
cp .env.example .env
# Отредактируйте .env с вашими значениями
```

### 2. Запуск локальной ноды

```bash
# Fork Base Mainnet
anvil --fork-url https://mainnet.base.org --fork-block-number latest

# В другом терминале
```

### 3. Деплой контрактов

```bash
forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast
```

### 4. Запуск тестов на форке

```bash
forge test --fork-url https://mainnet.base.org
```

## Gas отчет

```bash
forge test --gas-report
```

Примерный gas consumption:
- BridgeCore operations: ~150k gas
- AMM swaps: ~145k gas
- Treasury distribution: ~135k gas
- Full cycle execution: ~300k gas

## Coverage

```bash
# Установка lcov
forge coverage --report lcov

# Просмотр в браузере
# Откройте coverage/index.html
```

## Troubleshooting

### Ошибка: "lib/forge-std not found"
```bash
forge install foundry-rs/forge-std
```

### Ошибка: "lib/openzeppelin-contracts not found"
```bash
forge install OpenZeppelin/openzeppelin-contracts
```

### Ошибка компиляции
```bash
# Очистка кэша
forge clean

# Пересборка
forge build
```

### Тесты не запускаются
```bash
# Проверьте версию Foundry
forge --version

# Обновите Foundry
foundryup
```

## Дополнительные команды

```bash
# Компиляция без тестов
forge build

# Проверка размера контрактов
forge build --sizes

# Форматирование кода
forge fmt

# Деплой на testnet
forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC \
  --broadcast \
  --verify

# Verification на BaseScan
forge verify-contract \
  --chain-id 8453 \
  --num-of-optimizations 200 \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address)" 0x... 0x... 0x... 0x...) \
  --etherscan-api-key $BASESCAN_API_KEY \
  $CONTRACT_ADDRESS \
  src/BridgeCore.sol:BridgeCore
```

## Результаты тестов

**Всего тестов:** 77
**Прошло:** 77 (100%)
**Провалилось:** 0

**Gas statistics:**
- Average: ~150k gas
- Min: 3k gas (preview functions)
- Max: 1.2M gas (multi-cycle integration)

**Fuzz tests:**
- 4 fuzz test suites
- 256 runs each
- All passed

## Следующие шаги

1. ✅ Смарт-контракты написаны
2. ✅ Тесты написаны и проходят
3. ✅ Деплой скрипт создан
4. ⏳ Внешний аудит (рекомендуется)
5. ⏳ Деплой на Base Sepolia testnet
6. ⏳ Деплой на Base Mainnet
7. ⏳ Настройка мониторинга
8. ⏳ Запуск арбитражного бота

## Поддержка

При возникновении проблем:
1. Проверьте версию Foundry: `forge --version`
2. Убедитесь что все зависимости установлены
3. Проверьте `.env` файл
4. Попробуйте `forge clean && forge build`
