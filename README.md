# Flash-loan arbitrage bot (Solidity + Rust) — Base

Borrows WETH from Balancer (0% fee), sells it on the DEX where it's expensive, buys it back where it's cheap,
repays, keeps the difference. If the trade isn't profitable the whole transaction reverts.

```
contracts/   Solidity (Foundry)  FlashArb.sol + tests (mock + real Base fork)
bot/         Rust (alloy)        pool discovery, exact-profit math, simulation gate, executor
```

## What was verified
| Check | Result |
|---|---|
| 9 Solidity unit/fuzz tests (mocks) | pass |
| 2 fork tests vs real Balancer + Uniswap V2 + Sushi on Base | pass |
| 6 Rust math tests (closed-form optimum == brute force) | pass |
| End-to-end on an Anvil Base fork: bot found an artificial gap, simulated, sent | predicted profit == realised profit, to the wei |
| Live scan of real Base pools | works; **found no opportunities** (see below) |

## Quick start (all free, no real money)
```bash
# 0. tools:  curl -L https://foundry.paradigm.xyz | bash && foundryup ;  curl https://sh.rustup.rs | sh

# 1. contract tests
cd contracts
forge test                                                        # mocks only
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract Fork -vv

# 2. scan-only bot: no key, no gas, nothing deployed
cd ../bot
cp config.example.toml config.toml
cargo run --release -- config.toml

# 3. full pipeline on a local fork (fake money)
anvil --fork-url https://mainnet.base.org            # terminal A
cd contracts && forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
# put the address in bot/config.toml (contract = "..."), rpc_url = "http://127.0.0.1:8545"
PRIVATE_KEY=0xac09...ff80 cargo run --release -- config.toml      # dry_run = true first!
```

## Going live (costs a little gas)
1. Deploy on Base with a **fresh wallet holding ~$5–10 of ETH** — never your main wallet.
2. `export PRIVATE_KEY=...`, set `contract = "0x..."`, keep `dry_run = true` for a few days and read the logs.
3. Only then set `dry_run = false`.

## About "90%+ success"
* **Transaction success** ≥ 90% is achievable and is built in: every trade is `eth_call`-simulated against the real
  contract first, and is only sent if it passes *and* covers gas. The bot prints this rate.
* **Winning opportunities** is not something code alone controls. Real price gaps on Uniswap-V2-style pools get
  closed within the same block by professional bots. Expect the scanner to show "no opportunity" most of the time
  and to lose races when one does appear. A free public RPC (rate-limited, slower) makes this worse.
* Ways to improve your odds: a faster/dedicated RPC close to the sequencer, less-covered long-tail pools
  (riskier: honeypots, fee-on-transfer tokens; simulation catches most), more DEXes (Aerodrome, BaseSwap — verify
  factory addresses yourself), triangular routes, and listening to pending/flashblocks data.

## Limits / known gaps
* Supports Uniswap-V2-style pairs with the standard `swap` interface. Not V3, Curve, or Aerodrome stable pools.
* Balancer's Base vault holds limited WETH (~28 at time of writing) — that caps loan size (the bot reads it live).
* The flash loan fee is governance-controlled; it's 0 today. The contract reads the fee from the callback, so it stays correct.
* Unaudited, educational. Use small amounts. Anyone selling a "guaranteed profit" bot is usually scamming you.
