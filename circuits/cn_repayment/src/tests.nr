// SPDX-License-Identifier: BUSL-1.1

// Tests for cn_repayment.
//
// Each test computes the expected `total_repayment` off-circuit (in `u128`
// space mirroring the in-circuit math) and then calls `main` with the matching
// public input. Use a private helper to produce the commitment so the test
// reads close to the contract-side flow.

use crate::ANNUAL_BPS_SECS;
use crate::main;
use conversion_math::poseidon2_hash;

global ISSUED_AT: u128 = 1_700_000_000;
// 18 months later (~production-realistic accrual window).
global NOW_PRE_MATURITY: u128 = 1_700_000_000 + 18 * 30 * 86400;
global MATURITY_LATE: u128 = 1_700_000_000 + 24 * 30 * 86400;
global MATURITY_EARLY: u128 = 1_700_000_000 + 12 * 30 * 86400;

fn commit(principal: Field, rate_bps: Field, cap: Field, disc: Field, blinding: Field) -> Field {
    poseidon2_hash([principal, rate_bps, cap, disc, blinding])
}

fn accrued(principal: u128, rate_bps: u128, issued_at: u128, end_time: u128) -> u128 {
    let elapsed = end_time - issued_at;
    (principal * rate_bps * elapsed) / ANNUAL_BPS_SECS
}

#[test]
fn test_repay_pre_maturity_succeeds() {
    let principal: u128 = 250_000_000_000; // $250k @ 6 decimals
    let rate_bps: u128 = 600; // 6% APR
    let cap: u128 = 10_000_000_000_000; // $10M post-money cap
    let disc: u128 = 0;
    let blinding: Field = 0xCAFEF00D;

    let interest = accrued(principal, rate_bps, ISSUED_AT, NOW_PRE_MATURITY);
    let total = principal + interest;

    let terms_commitment = commit(
        principal as Field,
        rate_bps as Field,
        cap as Field,
        disc as Field,
        blinding,
    );

    main(
        principal as Field,
        rate_bps as Field,
        cap as Field,
        disc as Field,
        blinding,
        terms_commitment,
        ISSUED_AT as Field,
        MATURITY_LATE as Field,
        NOW_PRE_MATURITY as Field,
        total as Field,
    );
}

#[test]
fn test_repay_post_maturity_clamps_to_maturity() {
    // current_time > maturity_date -- interest stops accruing at maturity.
    let principal: u128 = 250_000_000_000;
    let rate_bps: u128 = 600;
    let blinding: Field = 0xCAFEF00D;

    let interest = accrued(principal, rate_bps, ISSUED_AT, MATURITY_EARLY);
    let total = principal + interest;

    let terms_commitment = commit(principal as Field, rate_bps as Field, 0, 0, blinding);

    main(
        principal as Field,
        rate_bps as Field,
        0,
        0,
        blinding,
        terms_commitment,
        ISSUED_AT as Field,
        MATURITY_EARLY as Field,
        NOW_PRE_MATURITY as Field,
        total as Field,
    );
}

#[test]
fn test_repay_at_issuance_zero_interest() {
    // current_time == issued_at -- zero elapsed, total == principal.
    let principal: u128 = 100_000_000_000;
    let rate_bps: u128 = 1500;
    let blinding: Field = 0xBEEF;

    let terms_commitment = commit(principal as Field, rate_bps as Field, 0, 0, blinding);

    main(
        principal as Field,
        rate_bps as Field,
        0,
        0,
        blinding,
        terms_commitment,
        ISSUED_AT as Field,
        MATURITY_LATE as Field,
        ISSUED_AT as Field,
        principal as Field,
    );
}

#[test(should_fail)]
fn test_repay_rejects_off_by_one() {
    // total_repayment is 1 less than expected -- circuit must reject.
    let principal: u128 = 250_000_000_000;
    let rate_bps: u128 = 600;
    let blinding: Field = 0xCAFEF00D;

    let interest = accrued(principal, rate_bps, ISSUED_AT, NOW_PRE_MATURITY);
    let total = principal + interest - 1;

    let terms_commitment = commit(principal as Field, rate_bps as Field, 0, 0, blinding);

    main(
        principal as Field,
        rate_bps as Field,
        0,
        0,
        blinding,
        terms_commitment,
        ISSUED_AT as Field,
        MATURITY_LATE as Field,
        NOW_PRE_MATURITY as Field,
        total as Field,
    );
}

#[test(should_fail)]
fn test_repay_rejects_wrong_commitment() {
    // Witness is fine but the public commitment doesn't open to it.
    let principal: u128 = 250_000_000_000;
    let rate_bps: u128 = 600;
    let blinding: Field = 0xCAFEF00D;
    let interest = accrued(principal, rate_bps, ISSUED_AT, NOW_PRE_MATURITY);

    let wrong_commitment: Field = 0xDEAD;

    main(
        principal as Field,
        rate_bps as Field,
        0,
        0,
        blinding,
        wrong_commitment,
        ISSUED_AT as Field,
        MATURITY_LATE as Field,
        NOW_PRE_MATURITY as Field,
        (principal + interest) as Field,
    );
}

#[test(should_fail)]
fn test_repay_rejects_current_before_issued() {
    // end_time < issued_at -- interest would be negative; circuit must reject.
    let principal: u128 = 250_000_000_000;
    let rate_bps: u128 = 600;
    let blinding: Field = 0xCAFEF00D;

    let terms_commitment = commit(principal as Field, rate_bps as Field, 0, 0, blinding);

    main(
        principal as Field,
        rate_bps as Field,
        0,
        0,
        blinding,
        terms_commitment,
        ISSUED_AT as Field,
        MATURITY_LATE as Field,
        (ISSUED_AT - 1) as Field,
        principal as Field,
    );
}
