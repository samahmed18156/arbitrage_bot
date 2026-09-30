//! Flash-loan arbitrage scanner / executor for Uniswap-V2-style DEXes.
//!
//! Pipeline per new block:
//!   1. read reserves of every pool that shares a quote token with another pool
//!   2. closed-form optimal size + exact integer profit           (math.rs)
//!   3. eth_call simulation of the real contract                  <- the "90%+" gate
//!   4. gas estimate, net-profit check
//!   5. send (only if dry_run = false)

mod math;

use alloy::{
    network::EthereumWallet,
    primitives::{utils::parse_ether, Address, U256},
    providers::{Provider, ProviderBuilder},
    signers::local::PrivateKeySigner,
    sol,
};
use anyhow::{Context, Result};
use futures::future::join_all;
use math::{best_trade, PoolState};
use serde::Deserialize;
use std::{collections::HashMap, time::Duration};
use tracing::{debug, info, warn};

sol! {
    #[sol(rpc)]
    interface IPair {
        function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
        function token0() external view returns (address);
    }
    #[sol(rpc)]
    interface IFactory {
        function getPair(address a, address b) external view returns (address);
    }
    #[sol(rpc)]
    interface IErc20 {
        function balanceOf(address a) external view returns (uint256);
        function symbol() external view returns (string);
    }
    #[sol(rpc)]
    interface IFlashArb {
        struct Route {
            address token;
            uint256 amount;
            address pairBuy;
            address pairSell;
            uint16 feeBuyBps;
            uint16 feeSellBps;
            uint256 minProfit;
        }
        function executeArb(Route calldata r) external;
    }
}

#[derive(Deserialize)]
struct DexCfg {
    name: String,
    factory: Address,
    fee_bps: u32,
}

#[derive(Deserialize)]
struct Config {
    rpc_url: String,
    vault: Address,
    base_token: Address,
    contract: Option<Address>,
    poll_ms: u64,
    dry_run: bool,
    min_net_profit_eth: f64,
    max_loan_eth: f64,
    #[serde(default)]
    slippage_safety_bps: u32,
    dex: Vec<DexCfg>,
    tokens: Vec<Address>,
}

#[derive(Clone)]
struct Pool {
    dex: String,
    pair: Address,
    fee_bps: u32,
    base_is_token0: bool,
}

#[derive(Default)]
struct Stats {
    blocks: u64,
    candidates: u64,
    sim_reverted: u64,
    unprofitable_after_gas: u64,
    sent: u64,
    succeeded: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
        .init();

    let path = std::env::args().nth(1).unwrap_or_else(|| "config.toml".into());
    let cfg: Config = toml::from_str(&std::fs::read_to_string(&path).with_context(|| format!("reading {path}"))?)?;

    // Key is only needed if a contract is configured. Otherwise use a throwaway signer (scan-only).
    let signer: PrivateKeySigner = match std::env::var("PRIVATE_KEY") {
        Ok(k) => k.trim().parse().context("PRIVATE_KEY is not a valid hex key")?,
        Err(_) => PrivateKeySigner::random(),
    };
    let me = signer.address();
    let provider = ProviderBuilder::new().wallet(EthereumWallet::from(signer)).connect_http(cfg.rpc_url.parse()?);

    let chain_id = provider.get_chain_id().await?;
    let min_net = parse_ether(&cfg.min_net_profit_eth.to_string())?;
    let max_loan = parse_ether(&cfg.max_loan_eth.to_string())?;
    let scan_only = cfg.contract.is_none();
    info!(chain_id, scan_only, dry_run = cfg.dry_run, "connected");
    if !scan_only && !cfg.dry_run {
        warn!("LIVE MODE: transactions will be sent from {me}");
    }

    // ---- discover pools -------------------------------------------------
    let mut groups: HashMap<Address, Vec<Pool>> = HashMap::new();
    for &q in &cfg.tokens {
        let sym = retry(|| async { IErc20::new(q, &provider).symbol().call().await }).await.unwrap_or_else(|_| "?".into());
        for d in &cfg.dex {
            let pair = retry(|| async { IFactory::new(d.factory, &provider).getPair(cfg.base_token, q).call().await }).await?;
            if pair == Address::ZERO {
                continue;
            }
            let t0 = retry(|| async { IPair::new(pair, &provider).token0().call().await }).await?;
            info!("pool {} {sym}: {pair}", d.name);
            groups.entry(q).or_default().push(Pool {
                dex: d.name.clone(),
                pair,
                fee_bps: d.fee_bps,
                base_is_token0: t0 == cfg.base_token,
            });
        }
    }
    groups.retain(|_, v| v.len() >= 2);
    anyhow::ensure!(!groups.is_empty(), "no quote token has pools on 2+ DEXes - check config");
    info!("watching {} token pairs", groups.len());

    let mut stats = Stats::default();
    let mut last_block = 0u64;
    let mut ticker = tokio::time::interval(Duration::from_millis(cfg.poll_ms));

    loop {
        tokio::select! {
            _ = ticker.tick() => {}
            _ = tokio::signal::ctrl_c() => {
                info!("shutting down. {}", summary(&stats));
                return Ok(());
            }
        }
        let bn = match provider.get_block_number().await {
            Ok(b) => b,
            Err(e) => { warn!("rpc error: {e}"); continue; }
        };
        if bn == last_block {
            continue;
        }
        last_block = bn;
        stats.blocks += 1;

        // Flash-loan liquidity available right now (cap loan at 95% of it)
        let vault_bal = IErc20::new(cfg.base_token, &provider).balanceOf(cfg.vault).call().await.unwrap_or(U256::ZERO);
        let cap = max_loan.min(vault_bal * U256::from(95u8) / U256::from(100u8));
        if cap.is_zero() {
            continue;
        }

        let gas_price = provider.get_gas_price().await.unwrap_or(0);

        for (quote, pools) in &groups {
            // 1. reserves, all pools concurrently
            let states: Vec<Option<PoolState>> = join_all(pools.iter().map(|p| async {
                let r = IPair::new(p.pair, &provider).getReserves().call().await.ok()?;
                let (r0, r1) = (r0_u128(&r.r0), r0_u128(&r.r1));
                let (base, quote) = if p.base_is_token0 { (r0, r1) } else { (r1, r0) };
                Some(PoolState { base, quote, fee_bps: p.fee_bps })
            }))
            .await;

            // 2. every ordered pair (sell base in i, buy back in j)
            for (i, a) in states.iter().enumerate() {
                for (j, b) in states.iter().enumerate() {
                    let (Some(a), Some(b)) = (a, b) else { continue };
                    if i == j { continue; }
                    let Some(t) = best_trade(*a, *b, cap) else { continue };
                    if t.gross_profit < min_net { continue; }
                    stats.candidates += 1;
                    info!(
                        block = bn, quote = %quote, sell_on = %pools[i].dex, buy_on = %pools[j].dex,
                        loan_eth = %fmt_eth(t.amount_in), gross_profit_eth = %fmt_eth(t.gross_profit),
                        "opportunity"
                    );

                    let Some(contract) = cfg.contract else { continue }; // scan-only

                    // 3. simulate with the real contract
                    // on-chain floor: keep at least half the expected profit (or less slippage)
                    let min_profit = if cfg.slippage_safety_bps > 0 {
                        t.gross_profit * U256::from(10_000 - cfg.slippage_safety_bps.min(10_000)) / U256::from(10_000)
                    } else {
                        t.gross_profit / U256::from(2u8)
                    };
                    let route = IFlashArb::Route {
                        token: cfg.base_token,
                        amount: t.amount_in,
                        pairBuy: pools[i].pair,
                        pairSell: pools[j].pair,
                        feeBuyBps: pools[i].fee_bps as u16,
                        feeSellBps: pools[j].fee_bps as u16,
                        minProfit: min_profit,
                    };
                    let c = IFlashArb::new(contract, &provider);
                    let call = c.executeArb(route).from(me);
                    if let Err(e) = call.call().await {
                        stats.sim_reverted += 1;
                        debug!("simulation reverted (not sent): {e}");
                        continue;
                    }

                    // 4. gas
                    let gas = match call.estimate_gas().await { Ok(g) => g, Err(e) => { debug!("gas est failed: {e}"); continue; } };
                    let gas_cost = U256::from(gas) * U256::from(gas_price) * U256::from(12u8) / U256::from(10u8); // +20% buffer
                    if t.gross_profit < gas_cost + min_net {
                        stats.unprofitable_after_gas += 1;
                        info!(gas, gas_cost_eth = %fmt_eth(gas_cost), "skipped: profit does not cover gas");
                        continue;
                    }

                    // 5. send
                    if cfg.dry_run {
                        info!(net_eth = %fmt_eth(t.gross_profit - gas_cost), "DRY RUN: simulation passed, would send");
                        continue;
                    }
                    stats.sent += 1;
                    match call.gas(gas * 12 / 10).send().await {
                        Ok(pending) => match pending.get_receipt().await {
                            Ok(r) if r.status() => {
                                stats.succeeded += 1;
                                info!(tx = %r.transaction_hash, "SUCCESS");
                            }
                            Ok(r) => warn!(tx = %r.transaction_hash, "tx reverted on-chain (lost the race?)"),
                            Err(e) => warn!("receipt error: {e}"),
                        },
                        Err(e) => warn!("send failed: {e}"),
                    }
                    info!("{}", summary(&stats));
                }
            }
        }
    }
}

/// Free public RPCs rate-limit (HTTP 429). Retry with backoff instead of crashing.
async fn retry<T, E: std::fmt::Display, F, Fut>(mut f: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = std::result::Result<T, E>>,
{
    let mut delay = 300;
    for attempt in 0..6 {
        match f().await {
            Ok(v) => return Ok(v),
            Err(e) if attempt < 5 => {
                debug!("rpc call failed ({e}); retrying in {delay}ms");
                tokio::time::sleep(Duration::from_millis(delay)).await;
                delay *= 2;
            }
            Err(e) => anyhow::bail!("rpc call failed after retries: {e}"),
        }
    }
    unreachable!()
}

fn r0_u128<const B: usize, const L: usize>(v: &alloy::primitives::Uint<B, L>) -> u128 {
    v.to::<u128>()
}

fn fmt_eth(v: U256) -> String {
    alloy::primitives::utils::format_ether(v)
}

fn summary(s: &Stats) -> String {
    let rate = if s.sent > 0 { 100.0 * s.succeeded as f64 / s.sent as f64 } else { 0.0 };
    format!(
        "blocks={} candidates={} sim_reverted={} skipped_gas={} sent={} ok={} ({rate:.0}% tx success)",
        s.blocks, s.candidates, s.sim_reverted, s.unprofitable_after_gas, s.sent, s.succeeded
    )
}
