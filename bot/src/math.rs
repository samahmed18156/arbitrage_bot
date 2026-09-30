//! Pure arbitrage math for two constant-product (Uniswap-V2 style) pools.
//! Route: base --(pool A)--> quote --(pool B)--> base.

use alloy::primitives::U256;

/// Exact Uniswap-V2 `getAmountOut` with a configurable fee (in bps).
pub fn amount_out(amount_in: U256, reserve_in: u128, reserve_out: u128, fee_bps: u32) -> U256 {
    if amount_in.is_zero() || reserve_in == 0 || reserve_out == 0 {
        return U256::ZERO;
    }
    let in_fee = amount_in * U256::from(10_000u32 - fee_bps);
    let num = in_fee * U256::from(reserve_out);
    let den = U256::from(reserve_in) * U256::from(10_000u32) + in_fee;
    num / den
}

/// Reserves of one pool, oriented (base, quote), plus its fee.
#[derive(Clone, Copy, Debug)]
pub struct PoolState {
    pub base: u128,
    pub quote: u128,
    pub fee_bps: u32,
}

/// Exact round-trip result for `amount_in` of base. Returns base received.
pub fn round_trip(amount_in: U256, a: PoolState, b: PoolState) -> U256 {
    let q = amount_out(amount_in, a.base, a.quote, a.fee_bps);
    amount_out(q, b.quote, b.base, b.fee_bps)
}

#[derive(Clone, Copy, Debug)]
pub struct Trade {
    pub amount_in: U256,
    pub gross_profit: U256,
}

/// Closed-form optimal input.
///
/// With ga = 1 - feeA, gb = 1 - feeB the round trip is  y(x) = K x / (M + N x)  where
///   K = ga gb qA bB,   M = bA qB,   N = ga (qB + gb qA)
/// Profit y - x is maximised when y'(x) = 1  =>  x* = (sqrt(K M) - M) / N.
/// A profitable opportunity exists iff K > M  (i.e. the marginal price gap beats both fees).
pub fn best_trade(a: PoolState, b: PoolState, max_in: U256) -> Option<Trade> {
    if a.base == 0 || a.quote == 0 || b.base == 0 || b.quote == 0 {
        return None;
    }
    let ga = 1.0 - a.fee_bps as f64 / 10_000.0;
    let gb = 1.0 - b.fee_bps as f64 / 10_000.0;
    let (a_b, a_q, b_b, b_q) = (a.base as f64, a.quote as f64, b.base as f64, b.quote as f64);

    let k = ga * gb * a_q * b_b;
    let m = a_b * b_q;
    let n = ga * (b_q + gb * a_q);
    if !(k > m) {
        return None;
    }
    let x = ((k * m).sqrt() - m) / n;
    if !x.is_finite() || x < 1.0 {
        return None;
    }
    let mut amount_in = U256::from(x.min(u128::MAX as f64) as u128);
    if amount_in > max_in {
        amount_in = max_in;
    }
    let out = round_trip(amount_in, a, b);
    if out <= amount_in {
        return None;
    }
    Some(Trade { amount_in, gross_profit: out - amount_in })
}

#[cfg(test)]
mod tests {
    use super::*;

    const E18: u128 = 1_000_000_000_000_000_000;

    fn pool(base_eth: u128, price: u128) -> PoolState {
        PoolState { base: base_eth * E18, quote: base_eth * price * E18, fee_bps: 30 }
    }

    #[test]
    fn matches_uniswap_formula() {
        // 1 ETH into 100 ETH / 200k USDC pool
        let out = amount_out(U256::from(E18), 100 * E18, 200_000 * E18, 30);
        assert_eq!(out, U256::from(1_974_316_068_794_122_597_700u128));
    }

    #[test]
    fn no_trade_when_prices_equal() {
        assert!(best_trade(pool(100, 2000), pool(100, 2000), U256::MAX).is_none());
    }

    #[test]
    fn no_trade_inside_fee_band() {
        // 0.4% gap < 0.6% round-trip fees
        let a = PoolState { base: 100 * E18, quote: 200_000 * E18, fee_bps: 30 };
        let b = PoolState { base: 100 * E18, quote: 200_800 * E18, fee_bps: 30 };
        assert!(best_trade(a, b, U256::MAX).is_none());
    }

    #[test]
    fn wrong_direction_is_none_right_direction_is_some() {
        let cheap = pool(100, 2000); // WETH cheap
        let dear = pool(100, 2200); // WETH dear
        // sell base where it is dear (A=dear), buy back where cheap (B=cheap)
        assert!(best_trade(dear, cheap, U256::MAX).is_some());
        assert!(best_trade(cheap, dear, U256::MAX).is_none());
    }

    #[test]
    fn closed_form_matches_brute_force() {
        let a = pool(100, 2200);
        let b = PoolState { base: 37 * E18, quote: 70_000 * E18, fee_bps: 30 };
        let t = best_trade(a, b, U256::MAX).unwrap();

        // scan 0.01 ETH steps up to 50 ETH for the true optimum
        let step = E18 / 100;
        let mut best = (U256::ZERO, U256::ZERO);
        for i in 1..5000u128 {
            let x = U256::from(i * step);
            let out = round_trip(x, a, b);
            if out > x && out - x > best.1 {
                best = (x, out - x);
            }
        }
        let diff = if t.amount_in > best.0 { t.amount_in - best.0 } else { best.0 - t.amount_in };
        assert!(diff <= U256::from(step), "closed form {} vs brute {}", t.amount_in, best.0);
        // profit at closed-form must be >= brute force (brute force is on a coarse grid)
        assert!(t.gross_profit >= best.1);
    }

    #[test]
    fn respects_max_in() {
        let t = best_trade(pool(100, 2200), pool(100, 2000), U256::from(E18 / 10)).unwrap();
        assert_eq!(t.amount_in, U256::from(E18 / 10));
    }
}
