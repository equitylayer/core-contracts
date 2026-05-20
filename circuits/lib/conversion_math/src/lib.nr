// SPDX-License-Identifier: BUSL-1.1

//! YC post-money conversion math, shared by SAFEs and CNs.
//!
//! All instruments converting in the same financing share one CC:
//!   CC = (fully_diluted + known_shares) * 1e18 / (1e18 - ratio_sum)
//! Cap-path slots contribute to `ratio_sum`; discount/no-terms slots contribute
//! pre-computed `known_shares`. Running SAFE and CN math as independent proofs
//! would give each its own slice and break dilution -- this lib owns the
//! aggregation so a single fix lands in one place.
//!
//! ## u128 arithmetic
//!
//! All share math is `u128`. Field `/` in Noir is modular inverse, which only
//! equals floor-division when exact; for our formulas it isn't, so we cast
//! witnesses through [`checked_u128`] (constrained-lossless cast) and do
//! arithmetic in `u128`. Also matches the Solidity integer division on-chain.
//!
//! ## Overflow margin
//!
//! The binding intermediate is `amount * cc` in [`cap_path_shares`], not the
//! visible `cap * 1e18`. As `ratio_sum -> CC_PRECISION`, `cc` blows up and the
//! product can overflow `u128` *before* `compute_cc`'s own underflow trips.
//! For documented inputs (`amount`, `fd + known_shares <= 1e15`),
//! `MIN_CC_DENOM = 1e10` keeps `cc <= 2e23` and `amount * cc <= 2e38 < 2^128`.
//! [`compute_cc`] asserts the margin explicitly.

// =============================================================================
// Constants
// =============================================================================

/// Fixed-point scale for the conversion coefficient. 1e18.
pub global CC_PRECISION: u128 = 1_000_000_000_000_000_000;
/// Fixed-point scale for share counts. 1e6, matches on-chain ShareToken decimals.
pub global SHARE_PRECISION: u128 = 1_000_000;
/// Basis-point denominator. 10_000 = 100%.
pub global BPS_DENOM: u128 = 10_000;
/// Floor on `CC_PRECISION - ratio_sum`. See "Overflow margin" above.
pub global MIN_CC_DENOM: u128 = 10_000_000_000;

/// Per-slot share-computation strategy. Field-typed so it fits the `[Field; N]`
/// witness arrays directly; comparisons use Field equality only.
pub global PATH_INACTIVE: Field = 0; // empty slot
pub global PATH_CAP: Field = 1; // converts on valuation cap
pub global PATH_DISCOUNT: Field = 2; // converts on discount
pub global PATH_NO_TERMS: Field = 3; // converts at round price

// =============================================================================
// Witness Casts
// =============================================================================

/// Cast `Field -> u128` with a circuit constraint that the value fits in 128 bits.
/// Without this, a malicious prover could do `Field >= 2^128` and the silent
/// truncation would feed garbage into the share math.
pub fn checked_u128(x: Field) -> u128 {
    let cast = x as u128;
    assert(cast as Field == x);
    cast
}

// =============================================================================
// Path consistency
// =============================================================================

/// For one slot: assert that `(is_active, path_choice, cap, disc)` is coherent.
/// Inactive slots must use `PATH_INACTIVE`; active slots must pick one of
/// CAP / DISCOUNT / NO_TERMS, and the choice must match which terms are non-zero.
/// Does NOT zero-pad the instrument-specific fields (`inv`, `principal`, etc.) --
/// each circuit's `main()` does that itself.
pub fn assert_path_consistent(is_active: Field, path_choice: Field, cap: Field, disc: Field) {
    assert((is_active == 0) | (is_active == 1));

    if is_active == 0 {
        assert(path_choice == PATH_INACTIVE);
    }

    if is_active == 1 {
        let has_cap = if cap == 0 { 0 } else { 1 };
        let has_discount = if disc == 0 { 0 } else { 1 };

        if path_choice == PATH_CAP {
            assert(has_cap == 1);
        }
        if path_choice == PATH_DISCOUNT {
            assert(has_discount == 1);
        }
        if path_choice == PATH_NO_TERMS {
            assert(has_cap == 0);
            assert(has_discount == 0);
        }
        assert(
            (path_choice == PATH_CAP)
                | (path_choice == PATH_DISCOUNT)
                | (path_choice == PATH_NO_TERMS),
        );
    }
}

// =============================================================================
// CC and per-slot share formulas
// =============================================================================

/// `CC = (fd + known_shares) * 1e18 / (1e18 - ratio_sum)`.
/// Asserts `ratio_sum + MIN_CC_DENOM <= CC_PRECISION` -- over-allocated rounds
/// fail here explicitly instead of via implicit underflow, and the margin
/// keeps `amount * cc` downstream safe from u128 overflow.
pub fn compute_cc(fully_diluted: u128, known_shares: u128, ratio_sum: u128) -> u128 {
    assert(ratio_sum + MIN_CC_DENOM <= CC_PRECISION);
    ((fully_diluted + known_shares) * CC_PRECISION) / (CC_PRECISION - ratio_sum)
}

/// `price * (1 - disc/BPS)`. Caller must ensure `disc < BPS_DENOM`.
pub fn discounted_price(price: u128, disc: u128) -> u128 {
    (price * (BPS_DENOM - disc)) / BPS_DENOM
}

/// Per-slot cap-path contribution to `ratio_sum`: `amount * 1e18 / cap`.
pub fn cap_path_ratio(amount: u128, cap: u128) -> u128 {
    (amount * CC_PRECISION) / cap
}

/// Floor a raw share count to a whole share. Share counts use SHARE_PRECISION
/// fixed-point, so `floor_to_whole(6_209_340_000) = 6_209_000_000` (6,209.34
/// -> 6,209). Keeps cap tables integer-clean; fractional remainders stay with
/// the company.
fn floor_to_whole(raw: u128) -> u128 {
    (raw / SHARE_PRECISION) * SHARE_PRECISION
}

/// `floor(amount * cc / cap)`. Used both as the canonical assertion and as one
/// side of the dual-path optimality check.
pub fn cap_path_shares(amount: u128, cc: u128, cap: u128) -> u128 {
    floor_to_whole((amount * cc) / cap)
}

/// `floor(amount * 1e6 / discounted_price)`.
pub fn discount_path_shares(amount: u128, price: u128, disc: u128) -> u128 {
    floor_to_whole((amount * SHARE_PRECISION) / discounted_price(price, disc))
}

/// `floor(amount * 1e6 / price)` -- SAFE/Note converts at the round price.
pub fn no_terms_path_shares(amount: u128, price: u128) -> u128 {
    floor_to_whole((amount * SHARE_PRECISION) / price)
}

// =============================================================================
// Poseidon2
// =============================================================================

/// Fixed-length Poseidon2 hash. Byte-equivalent to bb.js `poseidon2Hash` and
/// `@zkpassport/poseidon2` so the dapp + backend prover stay aligned.
/// Re-derives the FieldSponge construction stdlib's `Poseidon2::hash` uses
/// internally (helper is `pub(crate)` in Noir 1.0.0-beta.20).
pub fn poseidon2_hash<let N: u32>(input: [Field; N]) -> Field {
    let rate: u32 = 3;
    let two_pow_64: Field = 18446744073709551616;
    let iv: Field = (N as Field) * two_pow_64;

    let mut state: [Field; 4] = [0; 4];
    state[rate] = iv;
    let mut cache: [Field; 3] = [0; 3];
    let mut cache_size: u32 = 0;

    for i in 0..N {
        if cache_size == rate {
            for j in 0..rate {
                state[j] += cache[j];
            }
            state = std::hash::poseidon2_permutation(state);
            cache[0] = input[i];
            cache_size = 1;
        } else {
            cache[cache_size] = input[i];
            cache_size += 1;
        }
    }
    // Final squeeze.
    for j in 0..rate {
        if j < cache_size {
            state[j] += cache[j];
        }
    }
    state = std::hash::poseidon2_permutation(state);
    state[0]
}

/// `poseidon2([shares_issued, blinding])`. Same layout as the dapp + prover
/// helpers, so the on-chain public-input array stays consistent.
pub fn shares_commit(shares_issued: Field, blinding: Field) -> Field {
    poseidon2_hash([shares_issued, blinding])
}
