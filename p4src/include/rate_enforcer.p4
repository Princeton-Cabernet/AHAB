// Approx UPF. Copyright (c) Princeton University, all rights reserved
#include "define.h"

#define DROP_PROB_LOOKUP_TBL_SIZE 1024
typedef bit<5> shifted_rate_t; // lookup table sizes will be 2 ** (2 * sizeof(shifted_rate_t))
typedef bit<8> drop_prob_t;  // a drop probability in [0,1] transformed into an integer in [0,256]
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
    //drop_prob_t rng_output;
    drop_prob_t drop_probability = 0;     // set by lookup table to 1 - min(1, threshold / measured_rate)
    drop_prob_t drop_probability_lo = 0;  // set by lookup table to 1 - min(1, threshold_lo / measured_rate)
    drop_prob_t drop_probability_hi = 0;  // set by lookup table to 1 - min(1, threshold_hi / measured_rate)

    // Approximate division lookup table keys
    shifted_rate_t measured_rate_shifted;
    shifted_rate_t threshold_lo_shifted;
    shifted_rate_t threshold_shifted;
    shifted_rate_t threshold_hi_shifted;
    
    // difference (candidate - measured_rate) for each candidate
    byterate_t dthresh_lo = 0;
    byterate_t dthresh_mid = 0;
    byterate_t dthresh_hi = 0;

    // Flags to mark if each candidate was exceeded
    bit<1> lo_exceeded_flag = 0;
    bit<1> mid_exceeded_flag = 0;
    bit<1> hi_exceeded_flag = 0;
    
    @hidden
    Register<bit<8>, bit<8>>(32) flipflop_reg;
    @hidden
    RegisterAction<bit<8>, bit<8>, bit<8>>(flipflop_reg) get_flipflop = {
        void apply(inout bit<8> stored, out bit<8> returned) {
            if (stored == 1) {
                stored = 0;
            } else {
                stored = 1;
            }
            returned = stored;
        }
    };
    drop_prob_t rng_output = rng.get();
    bit<1> flipflop = (bit<1>) get_flipflop.execute(0);  // hack for easier comparisons using registers

    /* --------------------------------------------------------------------------------------
     *  Probabilistically set the drop flag based upon current fair rate threshold
     * -------------------------------------------------------------------------------------- */
    @hidden
    Register<drop_prob_pair_t, bit<8>>(32) drop_flag_mid_calculator;
    RegisterAction<drop_prob_pair_t, bit<8>, bit<8>>(drop_flag_mid_calculator) get_flip_drop_flag_mid_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<8> drop_decision) {
            // Compare register_hi to metadata1, set register_lo to metadata2
            if (stored_rng_vals.hi < drop_probability) {
                drop_decision = 1;
                stored_rng_vals.lo = rng_output;
            } else {
                drop_decision = 0;
                stored_rng_vals.lo = rng_output;
            }
        }
    };
    RegisterAction<drop_prob_pair_t, bit<8>, bit<8>>(drop_flag_mid_calculator) get_flop_drop_flag_mid_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<8> drop_decision) {
            // Compare register_lo to metadata1, set register_hi to metadata2
            if (stored_rng_vals.lo < drop_probability) {
                drop_decision = 1;
                stored_rng_vals.hi = rng_output;
            } else {
                drop_decision = 0;
                stored_rng_vals.hi = rng_output;
            }
        }
    };

    /* --------------------------------------------------------------------------------------
     *  Pretend to probabilistically drop using threshold_lo as the current fair rate threshold
     * -------------------------------------------------------------------------------------- */
    @hidden
    Register<drop_prob_pair_t, bit<8>>(32) drop_flag_lo_calculator;
    RegisterAction<drop_prob_pair_t, bit<8>, bit<8>>(drop_flag_lo_calculator) get_flip_drop_flag_lo_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<8> drop_decision) {
            // Compare register_hi to metadata1, set register_lo to metadata2
            if (stored_rng_vals.hi < drop_probability_lo) {
                drop_decision = 1;
                stored_rng_vals.lo = rng_output;
            } else {
                drop_decision = 0;
                stored_rng_vals.lo = rng_output;
            }
        }
    };
    RegisterAction<drop_prob_pair_t, bit<8>, bit<8>>(drop_flag_lo_calculator) get_flop_drop_flag_lo_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<8> drop_decision) {
            // Compare register_lo to metadata1, set register_hi to metadata2
            if (stored_rng_vals.lo < drop_probability_lo) {
                drop_decision = 1;
                stored_rng_vals.hi = rng_output;
            } else {
                drop_decision = 0;
                stored_rng_vals.hi = rng_output;
            }
        }
    };

    /* --------------------------------------------------------------------------------------
     *  Pretend to probabilistically drop using threshold_hi as the current fair rate threshold
     * -------------------------------------------------------------------------------------- */
    @hidden
    Register<drop_prob_pair_t, bit<8>>(32) drop_flag_hi_calculator;
    RegisterAction<drop_prob_pair_t, bit<8>, bit<8>>(drop_flag_hi_calculator) get_flip_drop_flag_hi_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<8> drop_decision) {
            // Compare register_hi to metadata1, set register_lo to metadata2
            if (stored_rng_vals.hi < drop_probability_hi) {
                drop_decision = 1;
                stored_rng_vals.lo = rng_output;
            } else {
                drop_decision = 0;
                stored_rng_vals.lo = rng_output;
            }
        }
    };
    RegisterAction<drop_prob_pair_t, bit<8>, bit<8>>(drop_flag_hi_calculator) get_flop_drop_flag_hi_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<8> drop_decision) {
            // Compare register_lo to metadata1, set register_hi to metadata2
            if (stored_rng_vals.lo < drop_probability_hi) {
                drop_decision = 1;
                stored_rng_vals.hi = rng_output;
            } else {
                drop_decision = 0;
                stored_rng_vals.hi = rng_output;
            }
        }
    };


    /* --------------------------------------------------------------------------------------
     * Actions for calling the probabilistic drop registers
     * -------------------------------------------------------------------------------------- */
    // Mid (true) drop flag
    action get_flip_drop_flag_mid() {
        drop_flag_mid = (bit<1>) get_flip_drop_flag_mid_regact.execute(0);
    }
    action get_flop_drop_flag_mid() {
        drop_flag_mid = (bit<1>) get_flop_drop_flag_mid_regact.execute(0);
    }
    // Lo drop flag
    action get_flip_drop_flag_lo() {
        drop_flag_lo = (bit<1>) get_flip_drop_flag_lo_regact.execute(0);
    }
    action get_flop_drop_flag_lo() {
        drop_flag_lo = (bit<1>) get_flop_drop_flag_lo_regact.execute(0);
    }
    // Hi drop flag
    action get_flip_drop_flag_hi() {
        drop_flag_hi = (bit<1>) get_flip_drop_flag_hi_regact.execute(0);
    }
    action get_flop_drop_flag_hi() {
        drop_flag_hi = (bit<1>) get_flop_drop_flag_hi_regact.execute(0);
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
        threshold_shifted     = (shifted_rate_t) (threshold_mid  >> x);
        threshold_hi_shifted  = (shifted_rate_t) (threshold_hi   >> x);
        measured_rate_shifted = (shifted_rate_t) (measured_rate  >> x);
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
    // Grab true drop probability
    @hidden
    action load_drop_prob_mid_act(drop_prob_t prob) {
        drop_probability = prob;
    }
    @hidden
	table load_drop_prob_mid {
		key = {
            threshold_shifted : exact;
            measured_rate_shifted: exact;
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
    // Grab lo drop probability
    @hidden
    action load_drop_prob_lo_act(drop_prob_t prob) {
        drop_probability_lo = prob;
    }
    @hidden
	table load_drop_prob_lo {
		key = {
            threshold_lo_shifted : exact;
            measured_rate_shifted: exact;
		}
		actions = {
            load_drop_prob_lo_act;
        }
		default_action = load_drop_prob_lo_act(0);
        size = DROP_PROB_LOOKUP_TBL_SIZE;
        const entries = {
#include "actions_and_entries/load_drop_prob/const_entries_lo.p4inc"
        }
	}
    // Grab hi drop probability
    @hidden
    action load_drop_prob_hi_act(drop_prob_t prob) {
        drop_probability_hi = prob;
    }
    @hidden
	table load_drop_prob_hi {
		key = {
            threshold_hi_shifted : exact;
            measured_rate_shifted: exact;
		}
		actions = {
            load_drop_prob_hi_act;
        }
		default_action=load_drop_prob_hi_act(0);
        size = DROP_PROB_LOOKUP_TBL_SIZE;
        const entries = {
#include "actions_and_entries/load_drop_prob/const_entries_hi.p4inc"
        }
	}

    action calculate_threshold_differences_act() {
        dthresh_lo  = threshold_lo - measured_rate;
        dthresh_mid = threshold_mid - measured_rate;
        dthresh_hi  = threshold_hi - measured_rate;
    }
    table calculate_threshold_differences_tbl {
        key = {}
        actions = {
            calculate_threshold_differences_act;
        }
        size = 1;
        default_action = calculate_threshold_differences_act;
    }

    apply {
        // Check if each of the threshold candidates were exceeded. If a candidate is not exceeded,
        // the drop flag is set to 0. This resolves a bug where rounding candidates for use as a key in
        // the division lookup table was truncating higher bits and leading to incorrect drops in many cases
        calculate_threshold_differences_tbl.apply();
        check_lo_exceeded.apply();
        check_mid_exceeded.apply();
        check_hi_exceeded.apply();
        // Approximate rates as narrower integers for use in the lookup tables
        shift_measured_rate.apply();
        // Lookup tables for true and simulated drop probabilities.
        // Each table is actually identical, but we need one copy for parallel computing of the three probabilities :(
        load_drop_prob_lo.apply();
        load_drop_prob_mid.apply();
        load_drop_prob_hi.apply();
        
        // Get true drop flag and simulated drop flags, by comparing
        //  lookup table outputs to an RNG value. If rng < output, mark to drop.
        if (flipflop == 1) {
            if (lo_exceeded_flag == 1) {
                get_flip_drop_flag_lo();
            } else {
                drop_flag_lo = 0;
            }
            if (mid_exceeded_flag == 1) {
                get_flip_drop_flag_mid();
            } else {
                drop_flag_mid = 0;
            }
            if (hi_exceeded_flag == 1) {
                get_flip_drop_flag_hi();
            } else {
                drop_flag_hi = 0;
            }
        } else {
            if (lo_exceeded_flag == 1) {
                get_flop_drop_flag_lo();
            } else {
                drop_flag_lo = 0;
            }
            if (mid_exceeded_flag == 1) {
                get_flop_drop_flag_mid();
            } else {
                drop_flag_mid = 0;
            }
            if (hi_exceeded_flag == 1) {
                get_flop_drop_flag_hi();
            } else {
                drop_flag_hi = 0;
            }
        }
	}
}

