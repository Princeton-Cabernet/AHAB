// Approx UPF. Copyright (c) Princeton University, all rights reserved
#include "define.h"

#define DROP_PROB_LOOKUP_TBL_SIZE 2048
#define SIM_DROP_PROB_LOOKUP_TBL_SIZE 1024
typedef bit<5> shifted_rate_t; // lookup table sizes will be 2 ** (2 * sizeof(shifted_rate_t))
typedef bit<6> shifted_mid_rate_t; // lookup table sizes will be 2 ** (2 * sizeof(shifted_rate_t))
typedef bit<16> drop_prob_t;  // a drop probability in [0,1] transformed into an integer in [0,0x7fff] (15 bits)
const drop_prob_t MAX_DROP_PROB = 0x7fff; // 15 bits, 16th bit will be sign
struct drop_prob_pair_t {
    drop_prob_t hi;
    drop_prob_t lo;
}

control RateEnforcer(in byterate_t measured_rate,
                     in byterate_t threshold_lo,
                     in byterate_t threshold_mid,
                     in byterate_t threshold_hi,
                     out bit<1> drop_flag_lo,
                     out bit<1> drop_flag_mid,
                     out bit<1> drop_flag_hi) {
    /* This control block sets the drop flag with probability 1 - min(1, enforced_rate / measured_rate).
        Steps:
        - Approximate measured_rate, threshold_lo, threshold, and threshold_hi as i, j_lo, j, j_hi
        - Three lookup tables map (i, j*) to int( 2**sizeof(drop_prob_t) * (1 - min(1, j* / i)))
        - Compare lookup table output to an RNG value. If rng < val, mark to drop.
    */
    // TODO: check congestion flag, only drop if its 1
    // TODO: ensure candidates are not corrupted when only dropping during congestion

    Random<drop_prob_t>() rng;
    
    drop_prob_t rng_output;
    drop_prob_t drop_probability_mid_diff;     // set by lookup table to 1 - min(1, threshold / measured_rate)
    drop_prob_t drop_probability_lo_diff;   // set by lookup table to 1 - min(1, threshold_lo / measured_rate)
    drop_prob_t drop_probability_hi_diff;   // set by lookup table to 1 - min(1, threshold_hi / measured_rate)

    // Approximate division lookup table keys
    shifted_mid_rate_t measured_rate_mid_shifted;  // real
    shifted_mid_rate_t threshold_mid_shifted;  // real
    shifted_rate_t measured_rate_shifted;  // simulated
    shifted_rate_t threshold_lo_shifted;  // simulated
    shifted_rate_t threshold_hi_shifted;  // simulated
    
    // difference (candidate - measured_rate) for each candidate
    byterate_t dthresh_lo = 0;
    byterate_t dthresh_mid = 0;
    byterate_t dthresh_hi = 0;

    // Flags to mark if each candidate was exceeded
    bit<1> lo_exceeded_flag = 0;
    bit<1> mid_exceeded_flag = 0;
    bit<1> hi_exceeded_flag = 0;


    /* --------------------------------------------------------------------------------------
     * Tables for checking differences between drop probabilities and RNG output
     * -------------------------------------------------------------------------------------- */
    // Width of these values is sizeof(drop_prob_t)
#define TERNARY_NEG_CHECK_16 16w8000 &&& 16w8000
#define TERNARY_NONNEG_CHECK_16 16w0000 &&& 16w8000

    // Lo drop flag table
    action set_drop_flag_lo(bit<1> flag) {
        drop_flag_lo = flag;
    }
    table get_drop_flag_lo {
        key = {
            drop_probability_lo_diff : ternary; 
        }
        actions = {
            set_drop_flag_lo;
        }
        size = 4;
        const entries = {
            (TERNARY_NEG_CHECK_16)    : set_drop_flag_lo(0);  // rng was bigger than drop probability
            (TERNARY_NONNEG_CHECK_16) : set_drop_flag_lo(1);  // rng was smaller than drop probability
        }
        default_action = set_drop_flag_lo(0);  // Defensive, shouldn't be hit.
    }

    // True drop flag table
    action set_drop_flag_mid(bit<1> flag) {
        drop_flag_mid = flag;
    }
    table get_drop_flag_mid {
        key = {
            drop_probability_mid_diff : ternary; 
        }
        actions = {
            set_drop_flag_mid;
        }
        size = 4;
        const entries = {
            (TERNARY_NEG_CHECK_16)    : set_drop_flag_mid(0);  // rng was bigger than drop probability
            (TERNARY_NONNEG_CHECK_16) : set_drop_flag_mid(1);  // rng was smaller than drop probability
        }
        default_action = set_drop_flag_mid(0);  // Defensive, shouldn't be hit.
    }

    // Hi drop flag table
    action set_drop_flag_hi(bit<1> flag) {
        drop_flag_hi = flag;
    }
    table get_drop_flag_hi {
        key = {
            drop_probability_hi_diff : ternary; 
        }
        actions = {
            set_drop_flag_hi;
        }
        size = 4;
        const entries = {
            (TERNARY_NEG_CHECK_16)    : set_drop_flag_hi(0);  // rng was bigger than drop probability
            (TERNARY_NONNEG_CHECK_16) : set_drop_flag_hi(1);  // rng was smaller than drop probability
        }
        default_action = set_drop_flag_hi(0);  // Defensive, shouldn't be hit.
    }


// width of this key and mask should equal sizeof(byterate_t)
#define TERNARY_NEG_CHECK 32w0x80000000 &&& 32w0x80000000

    @hidden
    action set_lo_exceeded_flag(bit<1> flag) { 
        lo_exceeded_flag = flag;
    }
    @hidden
    table check_lo_exceeded { 
        key = {
            dthresh_lo  : ternary;
        }
        actions = {
            set_lo_exceeded_flag;
        }
        size = 2;
        const entries = {
            (TERNARY_NEG_CHECK) : set_lo_exceeded_flag(1);
        }
        default_action = set_lo_exceeded_flag(0);
    }
    @hidden
    action set_mid_exceeded_flag(bit<1> flag) { 
        mid_exceeded_flag = flag;
    }
    @hidden
    table check_mid_exceeded { 
        key = {
            dthresh_mid  : ternary;
        }
        actions = {
            set_mid_exceeded_flag;
        }
        size = 2;
        const entries = {
            (TERNARY_NEG_CHECK) : set_mid_exceeded_flag(1);
        }
        default_action = set_mid_exceeded_flag(0);
    }
    @hidden
    action set_hi_exceeded_flag(bit<1> flag) { 
        hi_exceeded_flag = flag;
    }
    @hidden
    table check_hi_exceeded { 
        key = {
            dthresh_hi  : ternary;
        }
        actions = {
            set_hi_exceeded_flag;
        }
        size = 2;
        const entries = {
            (TERNARY_NEG_CHECK) : set_hi_exceeded_flag(1);
        }
        default_action = set_hi_exceeded_flag(0);
    }


    /* --------------------------------------------------------------------------------------
     * Approximate the fair rates and measured rate as narrower integers for the lookup table
     * -------------------------------------------------------------------------------------- */
#include "actions_and_entries/shift_measured_rate/action_defs.p4inc"
    /* Include actions of the form:
	action rshift_x() {
    	threshold_lo_shifted  = (shifted_rate_t) (threshold_lo   >> x);
        threshold_hi_shifted  = (shifted_rate_t) (threshold_hi   >> x);
        measured_rate_shifted = (shifted_rate_t) (measured_rate  >> x);
        threshold_mid_shifted     = (shifted_mid_rate_t) (threshold_mid  >> x);
        measured_rate_mid_shifted = (shifted_mid_rate_t) (measured_rate  >> x);
	}
    */
	table shift_measured_rate {
		key = {
            measured_rate: ternary;
        }
		actions = {
#include "actions_and_entries/shift_measured_rate/action_list.p4inc"
        }
		default_action = rshift_0();
        const entries = {
#include "actions_and_entries/shift_measured_rate/const_entries.p4inc"
        }
        size  = 32;
	}

    /* --------------------------------------------------------------------------------------
     * Lookup tables that map (i, j*) to int( 2**sizeof(drop_prob_t) * (1 - min(1, j* / i)))
     *  for j* in {j, j_lo, j_hi}.
     * We only care when i > j*, otherwise the drop rate is 0. Don't have lookup table entries
     *  for i < j*
     * -------------------------------------------------------------------------------------- */
    // Grab lo drop probability
    action load_drop_prob_lo_act(drop_prob_t prob) {
        drop_probability_lo_diff = prob - rng_output;
    }
	table load_drop_prob_lo {
		key = {
            threshold_lo_shifted : exact;
            measured_rate_shifted: exact;
		}
		actions = {
            load_drop_prob_lo_act;
        }
		default_action = load_drop_prob_lo_act(0);
        size = SIM_DROP_PROB_LOOKUP_TBL_SIZE;
        const entries = {
#include "actions_and_entries/load_drop_prob/const_entries_lo.p4inc"
        }
	}
    // Grab true drop probability
    action load_drop_prob_mid_act(drop_prob_t prob) {
        drop_probability_mid_diff = prob - rng_output;
    }
	table load_drop_prob_mid {
		key = {
            threshold_mid_shifted : exact;
            measured_rate_mid_shifted: exact;
		}
		actions = {
            load_drop_prob_mid_act;
        }
		default_action=load_drop_prob_mid_act(0);
        size = DROP_PROB_LOOKUP_TBL_SIZE;
        const entries = {
#include "actions_and_entries/load_drop_prob/const_entries_mid.p4inc"
        }
	}
    // Grab hi drop probability
    action load_drop_prob_hi_act(drop_prob_t prob) {
        drop_probability_hi_diff = prob - rng_output;
    }
	table load_drop_prob_hi {
		key = {
            threshold_hi_shifted : exact;
            measured_rate_shifted: exact;
		}
		actions = {
            load_drop_prob_hi_act;
        }
		default_action=load_drop_prob_hi_act(0);
        size = SIM_DROP_PROB_LOOKUP_TBL_SIZE;
        const entries = {
#include "actions_and_entries/load_drop_prob/const_entries_hi.p4inc"
        }
	}

    action calculate_threshold_differences_act() {
        dthresh_lo  = threshold_lo - measured_rate;
        dthresh_mid = threshold_mid - measured_rate;
        dthresh_hi  = threshold_hi - measured_rate;
        rng_output = rng.get();  // unrelated instruction piggybacking off this unconditional action
    }
    table calculate_threshold_differences_tbl {
        key = {}
        actions = {
            calculate_threshold_differences_act;
        }
        size = 1;
        default_action = calculate_threshold_differences_act;
    }


    action trim_rng_output_act() {
        rng_output = rng_output & MAX_DROP_PROB;  // Trim excess bits so rng_output doesn't exceed max drop probability
    }
    table trim_rng_output_tbl {
        key = {}
        actions = {
            trim_rng_output_act;
        }
        size = 1;
        default_action = trim_rng_output_act();
    }


    apply {
        // Check if each of the threshold candidates were exceeded. If a candidate is not exceeded,
        // the drop flag is set to 0. This resolves a bug where rounding candidates for use as a key in
        // the division lookup table was truncating higher bits and leading to incorrect drops in many cases
        calculate_threshold_differences_tbl.apply();
        check_lo_exceeded.apply();
        check_mid_exceeded.apply();
        check_hi_exceeded.apply();

        // Trim excess bits so rng_output doesn't exceed max drop probability
        trim_rng_output_tbl.apply();

        // Approximate rates as narrower integers for use in the lookup tables
        shift_measured_rate.apply();

        // Lookup tables for true and simulated drop probabilities.
        // Each table is functionally identical, but we need one copy for parallel computing of the three probabilities :(
        load_drop_prob_lo.apply();
        load_drop_prob_mid.apply();
        load_drop_prob_hi.apply();
        
        // Get true drop flag and simulated drop flags, by comparing
        //  lookup table outputs to an RNG value. If rng < output, mark to drop.
        get_drop_flag_lo.apply();
        get_drop_flag_mid.apply();
        get_drop_flag_hi.apply();
	}
}

