// SPDX-License-Identifier: BUSL-1.1

mod tests;

// Joint SAFE + CN conversion circuit.
//
// All outstanding SAFEs and CNs in a qualified financing convert at the SAME
// CC, against ONE shared cap table. Running per-instrument proofs each computes
// its own CC against its own slice and breaks dilution -- this circuit aggregates
// `ratio_sum` + `known_shares` across both halves so the single CC is consistent.
// SAFE-only / CN-only flows pass through the same circuit with the unused half
// padded inactive.
//
// CN slots use `total_amount = principal + accrued_interest` (computed below
// from the public `issued_at` / `maturity` / `current_time` triple); SAFE slots
// use `inv` directly. Math reuses `conversion_math` unchanged.
//
// MAX_SAFES + MAX_NOTES is a hard cap per financing -- splitting across proofs
// reintroduces the FD-inconsistency bug. Raise by recompiling + rotating the VK.

use conversion_math::{
    assert_path_consistent, cap_path_ratio, cap_path_shares, checked_u128, compute_cc,
    discount_path_shares, no_terms_path_shares, PATH_CAP, PATH_DISCOUNT, PATH_INACTIVE,
    PATH_NO_TERMS, poseidon2_hash,
};

global MAX_SAFES: u32 = 16;
global MAX_NOTES: u32 = 16;

// 365 days * 86400 sec * 10000 bps. denominator for simple interest accrual.
global ANNUAL_BPS_SECS: u128 = 365 * 86400 * 10_000;

fn main(
    // SAFE private witness.
    safe_inv: [Field; MAX_SAFES],
    safe_cap: [Field; MAX_SAFES],
    safe_disc: [Field; MAX_SAFES],
    safe_mfn: [Field; MAX_SAFES],
    safe_pro_rata: [Field; MAX_SAFES],
    safe_blinding: [Field; MAX_SAFES],
    safe_shares_blinding: [Field; MAX_SAFES],
    safe_is_active: [Field; MAX_SAFES],
    safe_path_choice: [Field; MAX_SAFES],
    // CN private witness.
    cn_principal: [Field; MAX_NOTES],
    cn_rate_bps: [Field; MAX_NOTES],
    cn_cap: [Field; MAX_NOTES],
    cn_disc: [Field; MAX_NOTES],
    cn_blinding: [Field; MAX_NOTES],
    cn_shares_blinding: [Field; MAX_NOTES],
    cn_is_active: [Field; MAX_NOTES],
    cn_path_choice: [Field; MAX_NOTES],
    // Shared public scalars.
    batch_id: pub Field,
    price_per_share: pub Field,
    fully_diluted: pub Field,
    current_time: pub Field,
    // SAFE public per-slot.
    safe_terms_commitments: pub [Field; MAX_SAFES],
    safe_shares_issued: pub [Field; MAX_SAFES],
    safe_shares_commitments: pub [Field; MAX_SAFES],
    // CN public per-slot.
    cn_terms_commitments: pub [Field; MAX_NOTES],
    cn_issued_at: pub [Field; MAX_NOTES],
    cn_maturity_date: pub [Field; MAX_NOTES],
    cn_shares_issued: pub [Field; MAX_NOTES],
    cn_shares_commitments: pub [Field; MAX_NOTES],
) {
    let _ = batch_id;

    assert(price_per_share != 0);
    assert(fully_diluted != 0);

    // Verify each active slot's terms commitment. SAFE = 6-field poseidon2,
    // CN = 5-field (no mfn / pro_rata / time fields).
    for i in 0..MAX_SAFES {
        if safe_is_active[i] == 1 {
            let computed = poseidon2_hash([
                safe_inv[i],
                safe_cap[i],
                safe_disc[i],
                safe_mfn[i],
                safe_pro_rata[i],
                safe_blinding[i],
            ]);
            assert(computed == safe_terms_commitments[i]);
        }
    }
    for i in 0..MAX_NOTES {
        if cn_is_active[i] == 1 {
            let computed = poseidon2_hash([
                cn_principal[i],
                cn_rate_bps[i],
                cn_cap[i],
                cn_disc[i],
                cn_blinding[i],
            ]);
            assert(computed == cn_terms_commitments[i]);
        }
    }

    // Path consistency + zero-padding of inactive slots. Zero-padding is per
    // instrument because the field sets differ between SAFEs and CNs.
    for i in 0..MAX_SAFES {
        assert_path_consistent(
            safe_is_active[i],
            safe_path_choice[i],
            safe_cap[i],
            safe_disc[i],
        );

        if safe_is_active[i] == 0 {
            assert(safe_inv[i] == 0);
            assert(safe_cap[i] == 0);
            assert(safe_disc[i] == 0);
            assert(safe_mfn[i] == 0);
            assert(safe_pro_rata[i] == 0);
            assert(safe_blinding[i] == 0);
            assert(safe_shares_blinding[i] == 0);
        }
    }
    for i in 0..MAX_NOTES {
        assert_path_consistent(cn_is_active[i], cn_path_choice[i], cn_cap[i], cn_disc[i]);

        if cn_is_active[i] == 0 {
            assert(cn_principal[i] == 0);
            assert(cn_rate_bps[i] == 0);
            assert(cn_cap[i] == 0);
            assert(cn_disc[i] == 0);
            assert(cn_blinding[i] == 0);
            assert(cn_shares_blinding[i] == 0);
            assert(cn_issued_at[i] == 0);
            assert(cn_maturity_date[i] == 0);
        }
    }

    let price_u = checked_u128(price_per_share);
    let fully_diluted_u = checked_u128(fully_diluted);
    let current_time_u = checked_u128(current_time);

    // CN total = principal + accrued interest, clamped to maturity. SAFEs use
    // `safe_inv` directly downstream.
    let mut cn_total: [u128; MAX_NOTES] = [0; MAX_NOTES];
    for i in 0..MAX_NOTES {
        if cn_is_active[i] == 1 {
            let principal_u = checked_u128(cn_principal[i]);
            let rate_u = checked_u128(cn_rate_bps[i]);
            let issued_u = checked_u128(cn_issued_at[i]);
            let maturity_u = checked_u128(cn_maturity_date[i]);
            let end_time = if maturity_u < current_time_u {
                maturity_u
            } else {
                current_time_u
            };
            let elapsed = end_time - issued_u;
            let interest = (principal_u * rate_u * elapsed) / ANNUAL_BPS_SECS;
            cn_total[i] = principal_u + interest;
        }
    }

    // Joint aggregation across SAFE + CN halves, so CC reflects the full pool.
    let mut ratio_sum: u128 = 0;
    let mut known_shares: u128 = 0;

    for i in 0..MAX_SAFES {
        let pc = safe_path_choice[i];

        if pc == PATH_CAP {
            let inv_u = checked_u128(safe_inv[i]);
            let cap_u = checked_u128(safe_cap[i]);
            ratio_sum = ratio_sum + cap_path_ratio(inv_u, cap_u);
        }
        if pc == PATH_DISCOUNT {
            let inv_u = checked_u128(safe_inv[i]);
            let disc_u = checked_u128(safe_disc[i]);
            known_shares = known_shares + discount_path_shares(inv_u, price_u, disc_u);
        }
        if pc == PATH_NO_TERMS {
            let inv_u = checked_u128(safe_inv[i]);
            known_shares = known_shares + no_terms_path_shares(inv_u, price_u);
        }
    }

    for i in 0..MAX_NOTES {
        let pc = cn_path_choice[i];

        if pc == PATH_CAP {
            let cap_u = checked_u128(cn_cap[i]);
            ratio_sum = ratio_sum + cap_path_ratio(cn_total[i], cap_u);
        }
        if pc == PATH_DISCOUNT {
            let disc_u = checked_u128(cn_disc[i]);
            known_shares = known_shares + discount_path_shares(cn_total[i], price_u, disc_u);
        }
        if pc == PATH_NO_TERMS {
            known_shares = known_shares + no_terms_path_shares(cn_total[i], price_u);
        }
    }

    let cc: u128 = compute_cc(fully_diluted_u, known_shares, ratio_sum);

    // Per-slot share constraints. For dual-term slots (cap AND disc) the chosen
    // path must give >= shares than the rejected path -- the "investor gets the
    // better deal" rule.
    for i in 0..MAX_SAFES {
        let pc = safe_path_choice[i];

        if pc == PATH_INACTIVE {
            assert(safe_shares_issued[i] == 0);
        }

        if pc == PATH_CAP {
            let inv_u = checked_u128(safe_inv[i]);
            let cap_u = checked_u128(safe_cap[i]);
            let cap_shares = cap_path_shares(inv_u, cc, cap_u);
            assert(cap_shares == checked_u128(safe_shares_issued[i]));

            if safe_disc[i] != 0 {
                let disc_u = checked_u128(safe_disc[i]);
                let disc_shares = discount_path_shares(inv_u, price_u, disc_u);
                assert(cap_shares >= disc_shares);
            }
        }

        if pc == PATH_DISCOUNT {
            let inv_u = checked_u128(safe_inv[i]);
            let disc_u = checked_u128(safe_disc[i]);
            let disc_shares = discount_path_shares(inv_u, price_u, disc_u);
            assert(disc_shares == checked_u128(safe_shares_issued[i]));

            if safe_cap[i] != 0 {
                let cap_u = checked_u128(safe_cap[i]);
                let cap_shares = cap_path_shares(inv_u, cc, cap_u);
                assert(disc_shares >= cap_shares);
            }
        }

        if pc == PATH_NO_TERMS {
            let inv_u = checked_u128(safe_inv[i]);
            let shares = no_terms_path_shares(inv_u, price_u);
            assert(shares == checked_u128(safe_shares_issued[i]));
        }
    }

    for i in 0..MAX_NOTES {
        let pc = cn_path_choice[i];

        if pc == PATH_INACTIVE {
            assert(cn_shares_issued[i] == 0);
        }

        if pc == PATH_CAP {
            let cap_u = checked_u128(cn_cap[i]);
            let cap_shares = cap_path_shares(cn_total[i], cc, cap_u);
            assert(cap_shares == checked_u128(cn_shares_issued[i]));

            if cn_disc[i] != 0 {
                let disc_u = checked_u128(cn_disc[i]);
                let disc_shares = discount_path_shares(cn_total[i], price_u, disc_u);
                assert(cap_shares >= disc_shares);
            }
        }

        if pc == PATH_DISCOUNT {
            let disc_u = checked_u128(cn_disc[i]);
            let disc_shares = discount_path_shares(cn_total[i], price_u, disc_u);
            assert(disc_shares == checked_u128(cn_shares_issued[i]));

            if cn_cap[i] != 0 {
                let cap_u = checked_u128(cn_cap[i]);
                let cap_shares = cap_path_shares(cn_total[i], cc, cap_u);
                assert(disc_shares >= cap_shares);
            }
        }

        if pc == PATH_NO_TERMS {
            let shares = no_terms_path_shares(cn_total[i], price_u);
            assert(shares == checked_u128(cn_shares_issued[i]));
        }
    }

    // shares_commitment openings for active slots.
    for i in 0..MAX_SAFES {
        if safe_is_active[i] == 1 {
            let computed = poseidon2_hash([safe_shares_issued[i], safe_shares_blinding[i]]);
            assert(computed == safe_shares_commitments[i]);
        }
    }
    for i in 0..MAX_NOTES {
        if cn_is_active[i] == 1 {
            let computed = poseidon2_hash([cn_shares_issued[i], cn_shares_blinding[i]]);
            assert(computed == cn_shares_commitments[i]);
        }
    }
}
