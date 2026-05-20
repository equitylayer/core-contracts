// SPDX-License-Identifier: BUSL-1.1

mod tests;

// ConvertibleNote repayment circuit.
//
// Proves that a stated `total_repayment` is exactly `principal + accrued_interest`
// against a committed CN's terms. Used by `ConvertibleNote.repayNote`: the company
// states a public repayment amount and proves it matches the committed terms,
// without revealing principal or rate.
//
// Interest accrual mirrors the conversion circuit's CN branch:
//   elapsed = min(current_time, maturity_date) - issued_at
//   interest = principal * rate_bps * elapsed / ANNUAL_BPS_SECS
//
// Commitment layout is identical to the conversion circuit's CN branch (5-field Poseidon2):
//   terms_commitment = H(principal, rate_bps, cap, disc, blinding)
//
// `cap` and `disc` are committed but unused in the repayment math -- they are
// included so the same commitment opens for both conversion and repayment.

use conversion_math::{checked_u128, poseidon2_hash};

// 365 days * 86400 sec * 10000 bps. Denominator for simple interest accrual.
global ANNUAL_BPS_SECS: u128 = 365 * 86400 * 10_000;

fn main(
    // Private witness -- the CN's committed terms.
    principal: Field,
    rate_bps: Field,
    cap: Field,
    disc: Field,
    blinding: Field,
    // Public inputs.
    terms_commitment: pub Field,
    issued_at: pub Field,
    maturity_date: pub Field,
    current_time: pub Field,
    total_repayment: pub Field,
) {
    // 1. Commitment opens to the supplied witness.
    let computed = poseidon2_hash([principal, rate_bps, cap, disc, blinding]);
    assert(computed == terms_commitment);

    // 2. Time bookends. issued_at <= min(current_time, maturity_date), otherwise
    //    interest would be negative.
    let principal_u = checked_u128(principal);
    let rate_u = checked_u128(rate_bps);
    let issued_u = checked_u128(issued_at);
    let maturity_u = checked_u128(maturity_date);
    let current_u = checked_u128(current_time);

    let end_time = if maturity_u < current_u {
        maturity_u
    } else {
        current_u
    };
    assert(end_time >= issued_u);

    // 3. interest = principal * rate * elapsed / ANNUAL_BPS_SECS  (u128 arithmetic).
    let elapsed = end_time - issued_u;
    let interest = (principal_u * rate_u * elapsed) / ANNUAL_BPS_SECS;
    let expected = principal_u + interest;

    // 4. total_repayment must equal principal + accrued_interest exactly.
    assert(expected == checked_u128(total_repayment));
}
