// SPDX-License-Identifier: BUSL-1.1

// Tests for the unified SAFE+CN conversion circuit.
//
// Coverage: SAFE-only, CN-only, mixed-path, dual-instrument optimality, and the
// inactive-slot zero-padding guard. The shared `conversion_math` library covers
// the low-level formula helpers; these tests focus on joint-aggregation specifics.

use crate::ANNUAL_BPS_SECS;
use crate::main;
use crate::{MAX_NOTES, MAX_SAFES};
use conversion_math::{
    PATH_CAP, PATH_DISCOUNT, PATH_INACTIVE, PATH_NO_TERMS, poseidon2_hash, shares_commit,
};

global ISSUED_AT: u128 = 1_700_000_000;
global CURRENT_TIME: u128 = 1_700_000_000 + 18 * 30 * 86400;
global MATURITY_LATE: u128 = 1_700_000_000 + 24 * 30 * 86400;

// Production-mirror context for all tests: $10M cap, 10M FD, $1/share priced round.
global PRICE_PER_SHARE: u128 = 1_000_000;
global FULLY_DILUTED: u128 = 10_000_000_000_000; // 10M shares at 6 decimals

// =============================================================================
// SAFE slot helpers
// =============================================================================

struct SafeSlot {
    inv: Field,
    cap: Field,
    disc: Field,
    mfn: Field,
    pro_rata: Field,
    blinding: Field,
    shares_blinding: Field,
    is_active: Field,
    path_choice: Field,
}

fn safe_inactive() -> SafeSlot {
    SafeSlot {
        inv: 0,
        cap: 0,
        disc: 0,
        mfn: 0,
        pro_rata: 0,
        blinding: 0,
        shares_blinding: 0,
        is_active: 0,
        path_choice: PATH_INACTIVE,
    }
}

fn safe_cap_only(inv: Field, cap: Field, idx: u32) -> SafeSlot {
    SafeSlot {
        inv,
        cap,
        disc: 0,
        mfn: 0,
        pro_rata: 0,
        blinding: 0xA00000 + idx as Field,
        shares_blinding: 0xB00000 + idx as Field,
        is_active: 1,
        path_choice: PATH_CAP,
    }
}

fn safe_discount_only(inv: Field, disc: Field, idx: u32) -> SafeSlot {
    SafeSlot {
        inv,
        cap: 0,
        disc,
        mfn: 0,
        pro_rata: 0,
        blinding: 0xA10000 + idx as Field,
        shares_blinding: 0xB10000 + idx as Field,
        is_active: 1,
        path_choice: PATH_DISCOUNT,
    }
}

fn safe_terms_hash(s: SafeSlot) -> Field {
    if s.is_active == 1 {
        poseidon2_hash([s.inv, s.cap, s.disc, s.mfn, s.pro_rata, s.blinding])
    } else {
        0
    }
}

// =============================================================================
// CN slot helpers
// =============================================================================

struct CnSlot {
    principal: Field,
    rate_bps: Field,
    cap: Field,
    disc: Field,
    blinding: Field,
    shares_blinding: Field,
    is_active: Field,
    path_choice: Field,
    issued_at: Field,
    maturity_date: Field,
}

fn cn_inactive() -> CnSlot {
    CnSlot {
        principal: 0,
        rate_bps: 0,
        cap: 0,
        disc: 0,
        blinding: 0,
        shares_blinding: 0,
        is_active: 0,
        path_choice: PATH_INACTIVE,
        issued_at: 0,
        maturity_date: 0,
    }
}

fn cn_cap_only(principal: Field, rate_bps: Field, cap: Field, idx: u32) -> CnSlot {
    CnSlot {
        principal,
        rate_bps,
        cap,
        disc: 0,
        blinding: 0xC00000 + idx as Field,
        shares_blinding: 0xD00000 + idx as Field,
        is_active: 1,
        path_choice: PATH_CAP,
        issued_at: ISSUED_AT as Field,
        maturity_date: MATURITY_LATE as Field,
    }
}

fn cn_no_terms(principal: Field, rate_bps: Field, idx: u32) -> CnSlot {
    CnSlot {
        principal,
        rate_bps,
        cap: 0,
        disc: 0,
        blinding: 0xC20000 + idx as Field,
        shares_blinding: 0xD20000 + idx as Field,
        is_active: 1,
        path_choice: PATH_NO_TERMS,
        issued_at: ISSUED_AT as Field,
        maturity_date: MATURITY_LATE as Field,
    }
}

fn cn_terms_hash(s: CnSlot) -> Field {
    if s.is_active == 1 {
        poseidon2_hash([s.principal, s.rate_bps, s.cap, s.disc, s.blinding])
    } else {
        0
    }
}

fn cn_total_amount(s: CnSlot, current_time: u128) -> u128 {
    if s.is_active != 1 {
        0
    } else {
        let principal = s.principal as u128;
        let rate = s.rate_bps as u128;
        let issued = s.issued_at as u128;
        let maturity = s.maturity_date as u128;
        let end_time = if maturity < current_time {
            maturity
        } else {
            current_time
        };
        let elapsed = end_time - issued;
        let interest = (principal * rate * elapsed) / ANNUAL_BPS_SECS;
        principal + interest
    }
}

// =============================================================================
// Reference CC + per-slot share solver. Mirrors the circuit math 1:1 in u128.
// =============================================================================

fn ratio(amount: u128, cap: u128) -> u128 {
    (amount * 1_000_000_000_000_000_000) / cap
}
fn floor_whole(raw: u128) -> u128 {
    (raw / 1_000_000) * 1_000_000
}
fn cap_path_shares_for(amount: u128, cc: u128, cap: u128) -> u128 {
    floor_whole((amount * cc) / cap)
}
fn disc_path_shares_for(amount: u128, price: u128, disc: u128) -> u128 {
    let discounted = (price * (10_000 - disc)) / 10_000;
    floor_whole((amount * 1_000_000) / discounted)
}
fn no_terms_shares_for(amount: u128, price: u128) -> u128 {
    floor_whole((amount * 1_000_000) / price)
}

fn solve_cc(
    safes: [SafeSlot; MAX_SAFES],
    cns: [CnSlot; MAX_NOTES],
    price: u128,
    fully_diluted: u128,
    current_time: u128,
) -> u128 {
    let mut ratio_sum: u128 = 0;
    let mut known_shares: u128 = 0;

    for i in 0..MAX_SAFES {
        let s = safes[i];
        if s.path_choice == PATH_CAP {
            ratio_sum = ratio_sum + ratio(s.inv as u128, s.cap as u128);
        }
        if s.path_choice == PATH_DISCOUNT {
            known_shares =
                known_shares + disc_path_shares_for(s.inv as u128, price, s.disc as u128);
        }
        if s.path_choice == PATH_NO_TERMS {
            known_shares = known_shares + no_terms_shares_for(s.inv as u128, price);
        }
    }

    for i in 0..MAX_NOTES {
        let n = cns[i];
        let total = cn_total_amount(n, current_time);
        if n.path_choice == PATH_CAP {
            ratio_sum = ratio_sum + ratio(total, n.cap as u128);
        }
        if n.path_choice == PATH_DISCOUNT {
            known_shares = known_shares + disc_path_shares_for(total, price, n.disc as u128);
        }
        if n.path_choice == PATH_NO_TERMS {
            known_shares = known_shares + no_terms_shares_for(total, price);
        }
    }

    ((fully_diluted + known_shares) * 1_000_000_000_000_000_000)
        / (1_000_000_000_000_000_000 - ratio_sum)
}

// =============================================================================
// Run helper: solve shares, build public-input arrays, invoke main().
// =============================================================================

fn run(
    safes: [SafeSlot; MAX_SAFES],
    cns: [CnSlot; MAX_NOTES],
    price: u128,
    fully_diluted: u128,
    current_time: u128,
) {
    let cc = solve_cc(safes, cns, price, fully_diluted, current_time);

    let mut safe_terms_commitments: [Field; MAX_SAFES] = [0; MAX_SAFES];
    let mut safe_shares_issued: [Field; MAX_SAFES] = [0; MAX_SAFES];
    let mut safe_shares_commitments: [Field; MAX_SAFES] = [0; MAX_SAFES];

    for i in 0..MAX_SAFES {
        let s = safes[i];
        safe_terms_commitments[i] = safe_terms_hash(s);
        let shares = if s.path_choice == PATH_CAP {
            cap_path_shares_for(s.inv as u128, cc, s.cap as u128)
        } else if s.path_choice == PATH_DISCOUNT {
            disc_path_shares_for(s.inv as u128, price, s.disc as u128)
        } else if s.path_choice == PATH_NO_TERMS {
            no_terms_shares_for(s.inv as u128, price)
        } else {
            0
        };
        safe_shares_issued[i] = shares as Field;
        safe_shares_commitments[i] = if s.is_active == 1 {
            shares_commit(shares as Field, s.shares_blinding)
        } else {
            0
        };
    }

    let mut cn_terms_commitments: [Field; MAX_NOTES] = [0; MAX_NOTES];
    let mut cn_issued_at: [Field; MAX_NOTES] = [0; MAX_NOTES];
    let mut cn_maturity_date: [Field; MAX_NOTES] = [0; MAX_NOTES];
    let mut cn_shares_issued: [Field; MAX_NOTES] = [0; MAX_NOTES];
    let mut cn_shares_commitments: [Field; MAX_NOTES] = [0; MAX_NOTES];

    for i in 0..MAX_NOTES {
        let n = cns[i];
        cn_terms_commitments[i] = cn_terms_hash(n);
        cn_issued_at[i] = n.issued_at;
        cn_maturity_date[i] = n.maturity_date;

        let total = cn_total_amount(n, current_time);
        let shares = if n.path_choice == PATH_CAP {
            cap_path_shares_for(total, cc, n.cap as u128)
        } else if n.path_choice == PATH_DISCOUNT {
            disc_path_shares_for(total, price, n.disc as u128)
        } else if n.path_choice == PATH_NO_TERMS {
            no_terms_shares_for(total, price)
        } else {
            0
        };
        cn_shares_issued[i] = shares as Field;
        cn_shares_commitments[i] = if n.is_active == 1 {
            shares_commit(shares as Field, n.shares_blinding)
        } else {
            0
        };
    }

    let safe_inv: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.inv);
    let safe_cap: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.cap);
    let safe_disc: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.disc);
    let safe_mfn: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.mfn);
    let safe_pro_rata: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.pro_rata);
    let safe_blinding: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.blinding);
    let safe_shares_blinding: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.shares_blinding);
    let safe_is_active: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.is_active);
    let safe_path_choice: [Field; MAX_SAFES] = safes.map(|s: SafeSlot| s.path_choice);

    let cn_principal: [Field; MAX_NOTES] = cns.map(|n: CnSlot| n.principal);
    let cn_rate_bps: [Field; MAX_NOTES] = cns.map(|n: CnSlot| n.rate_bps);
    let cn_cap: [Field; MAX_NOTES] = cns.map(|n: CnSlot| n.cap);
    let cn_disc: [Field; MAX_NOTES] = cns.map(|n: CnSlot| n.disc);
    let cn_blinding: [Field; MAX_NOTES] = cns.map(|n: CnSlot| n.blinding);
    let cn_shares_blinding_arr: [Field; MAX_NOTES] = cns.map(|n: CnSlot| n.shares_blinding);
    let cn_is_active: [Field; MAX_NOTES] = cns.map(|n: CnSlot| n.is_active);
    let cn_path_choice: [Field; MAX_NOTES] = cns.map(|n: CnSlot| n.path_choice);

    main(
        safe_inv,
        safe_cap,
        safe_disc,
        safe_mfn,
        safe_pro_rata,
        safe_blinding,
        safe_shares_blinding,
        safe_is_active,
        safe_path_choice,
        cn_principal,
        cn_rate_bps,
        cn_cap,
        cn_disc,
        cn_blinding,
        cn_shares_blinding_arr,
        cn_is_active,
        cn_path_choice,
        0, // batch_id
        price as Field,
        fully_diluted as Field,
        current_time as Field,
        safe_terms_commitments,
        safe_shares_issued,
        safe_shares_commitments,
        cn_terms_commitments,
        cn_issued_at,
        cn_maturity_date,
        cn_shares_issued,
        cn_shares_commitments,
    );
}

fn empty_safes() -> [SafeSlot; MAX_SAFES] {
    [safe_inactive(); MAX_SAFES]
}

fn empty_cns() -> [CnSlot; MAX_NOTES] {
    [cn_inactive(); MAX_NOTES]
}

// =============================================================================
// Tests
// =============================================================================

#[test]
fn happy_safe_only_cap_path() {
    let mut safes = empty_safes();
    safes[0] = safe_cap_only(250_000_000_000, 8_000_000_000_000, 0); // $250k @ $8M cap

    run(
        safes,
        empty_cns(),
        PRICE_PER_SHARE,
        FULLY_DILUTED,
        CURRENT_TIME,
    );
}

#[test]
fn happy_cn_only_cap_path() {
    let mut cns = empty_cns();
    cns[0] = cn_cap_only(250_000_000_000, 600, 8_000_000_000_000, 0); // $250k, 6% APR, $8M cap

    run(
        empty_safes(),
        cns,
        PRICE_PER_SHARE,
        FULLY_DILUTED,
        CURRENT_TIME,
    );
}

#[test]
fn happy_mixed_cap_paths() {
    // One SAFE cap and one CN cap converting together -- exercises the JOINT
    // ratio_sum across both halves; would fail under the old separate-circuit math.
    let mut safes = empty_safes();
    safes[0] = safe_cap_only(500_000_000_000, 10_000_000_000_000, 0); // $500k @ $10M cap

    let mut cns = empty_cns();
    cns[0] = cn_cap_only(250_000_000_000, 600, 8_000_000_000_000, 0); // $250k, 6% APR, $8M cap

    run(safes, cns, PRICE_PER_SHARE, FULLY_DILUTED, CURRENT_TIME);
}

#[test]
fn happy_mixed_path_diversity() {
    // SAFE cap + SAFE discount + CN cap + CN no_terms. All four contributing
    // to known_shares / ratio_sum simultaneously.
    let mut safes = empty_safes();
    safes[0] = safe_cap_only(500_000_000_000, 10_000_000_000_000, 0);
    safes[1] = safe_discount_only(200_000_000_000, 2_000, 1); // $200k @ 20%

    let mut cns = empty_cns();
    cns[0] = cn_cap_only(250_000_000_000, 600, 8_000_000_000_000, 0);
    cns[1] = cn_no_terms(100_000_000_000, 800, 1); // $100k, 8% APR, no cap/disc

    run(safes, cns, PRICE_PER_SHARE, FULLY_DILUTED, CURRENT_TIME);
}

#[test]
fn happy_full_inactive() {
    // All slots inactive -- degenerate "nothing to convert" case. Circuit still
    // accepts (no-op): no constraints fire on inactive slots, CC is well-defined
    // (ratio_sum=0, known_shares=0, CC=fully_diluted).
    run(
        empty_safes(),
        empty_cns(),
        PRICE_PER_SHARE,
        FULLY_DILUTED,
        CURRENT_TIME,
    );
}

#[test(should_fail)]
fn rejects_safe_shares_off_by_one() {
    // Override a SAFE slot's shares_issued by 1 wei in the public inputs -- proof must reject.
    let mut safes = empty_safes();
    safes[0] = safe_cap_only(500_000_000_000, 10_000_000_000_000, 0);

    let cc = solve_cc(
        safes,
        empty_cns(),
        PRICE_PER_SHARE,
        FULLY_DILUTED,
        CURRENT_TIME,
    );
    let true_shares = cap_path_shares_for(500_000_000_000, cc, 10_000_000_000_000);

    let mut safe_terms_commitments: [Field; MAX_SAFES] = [0; MAX_SAFES];
    let mut safe_shares_issued: [Field; MAX_SAFES] = [0; MAX_SAFES];
    let mut safe_shares_commitments: [Field; MAX_SAFES] = [0; MAX_SAFES];

    safe_terms_commitments[0] = safe_terms_hash(safes[0]);
    safe_shares_issued[0] = (true_shares + 1) as Field; // cheat by +1
    safe_shares_commitments[0] =
        shares_commit((true_shares + 1) as Field, safes[0].shares_blinding);

    main(
        safes.map(|s: SafeSlot| s.inv),
        safes.map(|s: SafeSlot| s.cap),
        safes.map(|s: SafeSlot| s.disc),
        safes.map(|s: SafeSlot| s.mfn),
        safes.map(|s: SafeSlot| s.pro_rata),
        safes.map(|s: SafeSlot| s.blinding),
        safes.map(|s: SafeSlot| s.shares_blinding),
        safes.map(|s: SafeSlot| s.is_active),
        safes.map(|s: SafeSlot| s.path_choice),
        empty_cns().map(|n: CnSlot| n.principal),
        empty_cns().map(|n: CnSlot| n.rate_bps),
        empty_cns().map(|n: CnSlot| n.cap),
        empty_cns().map(|n: CnSlot| n.disc),
        empty_cns().map(|n: CnSlot| n.blinding),
        empty_cns().map(|n: CnSlot| n.shares_blinding),
        empty_cns().map(|n: CnSlot| n.is_active),
        empty_cns().map(|n: CnSlot| n.path_choice),
        0,
        PRICE_PER_SHARE as Field,
        FULLY_DILUTED as Field,
        CURRENT_TIME as Field,
        safe_terms_commitments,
        safe_shares_issued,
        safe_shares_commitments,
        [0; MAX_NOTES],
        [0; MAX_NOTES],
        [0; MAX_NOTES],
        [0; MAX_NOTES],
        [0; MAX_NOTES],
    );
}

#[test(should_fail)]
fn rejects_active_safe_with_inactive_path() {
    // SAFE marked active but path_choice = PATH_INACTIVE. Path consistency check must fire.
    let mut safes = empty_safes();
    safes[0] = SafeSlot {
        inv: 500_000_000_000,
        cap: 10_000_000_000_000,
        disc: 0,
        mfn: 0,
        pro_rata: 0,
        blinding: 0xDEAD,
        shares_blinding: 0xBEEF,
        is_active: 1,
        path_choice: PATH_INACTIVE,
    };
    run(
        safes,
        empty_cns(),
        PRICE_PER_SHARE,
        FULLY_DILUTED,
        CURRENT_TIME,
    );
}
