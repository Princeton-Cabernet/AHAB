// Approx UPF. Copyright (c) Princeton University, all rights reserved
#include "define.h"

#define DROP_PROB_LOOKUP_TBL_SIZE 512
typedef bit<5> shifted_rate_t; // lookup table sizes will be 2 ** (2 * sizeof(shifted_rate_t))
typedef bit<8> drop_prob_t;  // a drop probability in [0,1] transformed into an integer in [0,256]
struct drop_prob_pair_t {
    drop_prob_t hi;
    drop_prob_t lo;
}

control RateEnforcer(inout afd_metadata_t afd_md,
                     out bit<1> drop_flag) {
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

    shifted_rate_t measured_rate_shifted;
    shifted_rate_t threshold_lo_shifted;
    shifted_rate_t threshold_shifted;
    shifted_rate_t threshold_hi_shifted;

    bit<1> drop_flag_lo = 0;
    bit<1> drop_flag_hi = 0;
    
    @hidden
    Register<bit<1>, bit<1>>(1) flipflop_reg;
    @hidden
    RegisterAction<bit<8>, bit<1>, bit<8>>(flipflop_reg) get_flipflop = {
        void apply(inout bit<8> stored, out bit<8> returned) {
            if (stored == 1) {
                stored = 0;
                returned = 0;
            } else {
                stored = 1;
                returned = 1;
            }
        }
    };
    drop_prob_t rng_output = rng.get();
    bit<1> flipflop = (bit<1>) get_flipflop.execute(0);  // hack for easier comparisons using registers

    /* --------------------------------------------------------------------------------------
     *  Probabilistically set the drop flag based upon current fair rate threshold
     * -------------------------------------------------------------------------------------- */
    @hidden
    Register<drop_prob_pair_t, bit<1>>(1) drop_flag_calculator;
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_calculator) get_flip_drop_flag_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
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
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_calculator) get_flop_drop_flag_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
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
    Register<drop_prob_pair_t, bit<1>>(1) drop_flag_lo_calculator;
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_lo_calculator) get_flip_drop_flag_lo_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_hi to metadata1, set register_lo to metadata2
            if (stored_rng_vals.hi < drop_probability_lo) {
                drop_decision = 1w1;
                stored_rng_vals.lo = rng_output;
            } else {
                drop_decision = 1w0;
                stored_rng_vals.lo = rng_output;
            }
        }
    };
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_lo_calculator) get_flop_drop_flag_lo_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_lo to metadata1, set register_hi to metadata2
            if (stored_rng_vals.lo < drop_probability_lo) {
                drop_decision = 1w1;
                stored_rng_vals.hi = rng_output;
            } else {
                drop_decision = 1w0;
                stored_rng_vals.hi = rng_output;
            }
        }
    };

    /* --------------------------------------------------------------------------------------
     *  Pretend to probabilistically drop using threshold_hi as the current fair rate threshold
     * -------------------------------------------------------------------------------------- */
    @hidden
    Register<drop_prob_pair_t, bit<1>>(1) drop_flag_hi_calculator;
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_hi_calculator) get_flip_drop_flag_hi_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_hi to metadata1, set register_lo to metadata2
            if (stored_rng_vals.hi < drop_probability_hi) {
                drop_decision = 1w1;
                stored_rng_vals.lo = rng_output;
            } else {
                drop_decision = 1w0;
                stored_rng_vals.lo = rng_output;
            }
        }
    };
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_hi_calculator) get_flop_drop_flag_hi_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_lo to metadata1, set register_hi to metadata2
            if (stored_rng_vals.lo < drop_probability_hi) {
                drop_decision = 1w1;
                stored_rng_vals.hi = rng_output;
            } else {
                drop_decision = 1w0;
                stored_rng_vals.hi = rng_output;
            }
        }
    };


    /* --------------------------------------------------------------------------------------
     * Tables for calling the probabilistic drop registers
     * -------------------------------------------------------------------------------------- */
    // True drop flag table
    @hidden
    action get_flip_drop_flag() {
        drop_flag = get_flip_drop_flag_regact.execute(0);
    }
    @hidden
    action get_flop_drop_flag() {
        drop_flag = get_flop_drop_flag_regact.execute(0);
    }
    @hidden
    table get_drop_flag {
        key = {
            flipflop: exact;
        }
        actions = {
            get_flip_drop_flag;
            get_flop_drop_flag;
        }
        size = 2;
        const entries = {
            0 : get_flip_drop_flag();
            1 : get_flop_drop_flag();
        }
    }
    // Lo drop flag table
    @hidden
    action get_flip_drop_flag_lo() {
        drop_flag_lo = get_flip_drop_flag_lo_regact.execute(0);
    }
    @hidden
    action get_flop_drop_flag_lo() {
        drop_flag_lo = get_flop_drop_flag_lo_regact.execute(0);
    }
    @hidden
    table get_drop_flag_lo {
        key = {
            flipflop: exact;
        }
        actions = {
            get_flip_drop_flag_lo;
            get_flop_drop_flag_lo;
        }
        size = 2;
        const entries = {
            0 : get_flip_drop_flag_lo();
            1 : get_flop_drop_flag_lo();
        }
    }
    // Hi drop flag table
    @hidden
    action get_flip_drop_flag_hi() {
        drop_flag_hi = get_flip_drop_flag_hi_regact.execute(0);
    }
    @hidden
    action get_flop_drop_flag_hi() {
        drop_flag_hi = get_flop_drop_flag_hi_regact.execute(0);
    }
    @hidden
    table get_drop_flag_hi {
        key = {
            flipflop: exact;
        }
        actions = {
            get_flip_drop_flag_hi;
            get_flop_drop_flag_hi;
        }
        size = 2;
        const entries = {
            0 : get_flip_drop_flag_hi();
            1 : get_flop_drop_flag_hi();
        }
    }

    /* --------------------------------------------------------------------------------------
     * If this packet is going to actually be dropped, but threshold_lo or threshold_hi wouldn't have dropped it,
     * add the bytes of this packet to a per-slice byte store. The next non-dropped packet will pick up the bytes
     * and carry them to the egress rate estimators.
     * -------------------------------------------------------------------------------------- */
    @hidden
    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) byte_store_lo;
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_lo) combine_lo_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes + afd_md.scaled_pkt_len;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_lo) grab_lo_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_lo) dump_lo_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            dumped_bytes = dumped_bytes + afd_md.scaled_pkt_len;
            bytes_sent = 0;
        }
    };
    @hidden
    action combine_lo_bytes() {
        afd_md.bytes_sent_lo = combine_lo_bytes_regact.execute(afd_md.vlink_id);
    }
    @hidden
    action grab_lo_bytes() {
        afd_md.bytes_sent_lo = grab_lo_bytes_regact.execute(afd_md.vlink_id);
    }
    @hidden
    action dump_lo_bytes() {
        dump_lo_bytes_regact.execute(afd_md.vlink_id);
    }
    @hidden
    table dump_or_grab_lo_bytes {
        key = {
            drop_flag : exact;
            drop_flag_lo : exact;
        }
        actions = {
            dump_lo_bytes;
            grab_lo_bytes;
            combine_lo_bytes;
        }
        const entries = {
            (1, 0) : dump_lo_bytes();
            (0, 0) : combine_lo_bytes();
            (0, 1) : grab_lo_bytes();
            // (1,1) : no_action();
        }
        size = 4;
    }
    @hidden
    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) byte_store_hi;
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_hi) combine_hi_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes + afd_md.scaled_pkt_len;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_hi) grab_hi_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_hi) dump_hi_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            dumped_bytes = dumped_bytes + afd_md.scaled_pkt_len;
            bytes_sent = 0;
        }
    };
    @hidden
    action combine_hi_bytes() {
        afd_md.bytes_sent_hi = combine_hi_bytes_regact.execute(afd_md.vlink_id);
    }
    @hidden
    action grab_hi_bytes() {
        afd_md.bytes_sent_hi = grab_hi_bytes_regact.execute(afd_md.vlink_id);
    }
    @hidden
    action dump_hi_bytes() {
        dump_hi_bytes_regact.execute(afd_md.vlink_id);
    }
    // TODO: Do we need this? Given our current method for computing drop flags,
    //       it will never be the case that mid drops but hi doesn't.
    @hidden
    table dump_or_grab_hi_bytes {
        key = {
            drop_flag : exact;
            drop_flag_hi : exact;
        }
        actions = {
            dump_hi_bytes;
            grab_hi_bytes;
            combine_hi_bytes;
        }
        const entries = {
            (1, 0) : dump_hi_bytes();
            (0, 0) : combine_hi_bytes();
            (0, 1) : grab_hi_bytes();
            // (1,1) : no_action();
        }
        size = 4;
    }
    @hidden
    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) byte_store_all;
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_all) grab_all_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes + afd_md.scaled_pkt_len;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_all) dump_all_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            dumped_bytes = dumped_bytes + afd_md.scaled_pkt_len;
            bytes_sent = 0;
        }
    };
    @hidden
    action grab_all_bytes() {
        afd_md.bytes_sent_all = grab_all_bytes_regact.execute(afd_md.vlink_id);
    }
    @hidden
    action dump_all_bytes() {
        dump_all_bytes_regact.execute(afd_md.vlink_id);
    }
    @hidden
    table dump_or_grab_all_bytes {
        key = {
            drop_flag : exact;
        }
        actions = {
            dump_all_bytes;
            grab_all_bytes;
        }
        const entries = {
            0: grab_all_bytes();
            1 : dump_all_bytes();
        }
        size = 2;
    }


    /* --------------------------------------------------------------------------------------
     * Approximate the fair rates and measured rate as narrower integers for the lookup table
     * -------------------------------------------------------------------------------------- */
#include "actions_and_entries/shift_measured_rate/action_defs.p4inc"
    /* Include actions of the form:
	action rshift_x() {
        threshold_lo_shifted  = (shifted_rate_t) (afd_md.threshold_lo  >> x);
        threshold_shifted     = (shifted_rate_t) (afd_md.threshold     >> x);
        threshold_hi_shifted  = (shifted_rate_t) (afd_md.threshold_hi  >> x);
        measured_rate_shifted = (shifted_rate_t) (afd_md.measured_rate >> x);
	}
    */
	table shift_measured_rate {
		key = {
            afd_md.measured_rate: ternary;
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
    action load_drop_prob_act(drop_prob_t prob) {
        drop_probability = prob;
    }
    @hidden
	table load_drop_prob {
		key = {
            threshold_shifted : exact;
            measured_rate_shifted: exact;
		}
		actions = {
            load_drop_prob_act;
        }
		default_action=load_drop_prob_act(0);
        size = DROP_PROB_LOOKUP_TBL_SIZE;
        const entries = {
#include "actions_and_entries/load_drop_prob/const_entries.p4inc"
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

	apply {
        // Approximate rates as narrower integers for use in the lookup tables
        shift_measured_rate.apply();
        // Lookup tables for true and simulated drop probabilities.
        // Each table is actually identical, but we need one copy for parallel computing of the three probabilities :(
        load_drop_prob.apply();
        load_drop_prob_lo.apply();
        load_drop_prob_hi.apply();
        
        // Get true drop flag and simulated drop flags, by comparing
        //  lookup table outputs to an RNG value. If rng < output, mark to drop.
        get_drop_flag.apply();
        get_drop_flag_lo.apply();
        get_drop_flag_hi.apply();

        // If congestion flag is false, dropping is disabled
        if (afd_md.congestion_flag == 0) {
            afd_md.drop_withheld = drop_flag;
            drop_flag = 0;
        } else {  // Dropping is enabled
            // Deposit or pick up packet bytecounts to allow the lo/hi drop simulations to work around true dropping.
            dump_or_grab_lo_bytes.apply();
            dump_or_grab_hi_bytes.apply();
            dump_or_grab_all_bytes.apply();
        }
	}
}

