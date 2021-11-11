// Approx UPF. Copyright (c) Princeton University, all rights reserved
#include "define.h"

typedef bit<5> shifted_rate_t;
typedef bit<8> drop_prob_t;
struct drop_prob_pair_t {
    drop_prob_t hi;
    drop_prob_t lo;
}

control ProbabilisticDrop(inout afd_metadata_t afd_md,
                          inout bool drop_flag) {
    /* This control block sets the drop flag with probability 1 - min(1, enforced_rate / measured_rate).
        Steps:
        - Approximate measured_rate, fair_rate_lo, fair_rate, and fair_rate_hi as i, j_lo, j, j_hi
        - Three lookup tables map (i, j*) to int( 2**sizeof(drop_prob_t) * (1 - min(1, j* / i)))
        - Compare lookup table output to an RNG value. If rng < val, mark to drop.
    */

    Random<drop_prob_t>() rng;
    drop_prob_t rng_output;
    drop_prob_t drop_probability;     // set by lookup table to 1 - min(1, fair_rate / measured_rate)
    drop_prob_t drop_probability_lo;  // set by lookup table to 1 - min(1, fair_rate_lo / measured_rate)
    drop_prob_t drop_probability_hi;  // set by lookup table to 1 - min(1, fair_rate_hi / measured_rate)

    shifted_rate_t measured_rate_shifted;
    shifted_rate_t fair_rate_lo_shifted;
    shifted_rate_t fair_rate_shifted;
    shifted_rate_t fair_rate_hi_shifted;

    bool drop_flag_lo;
    bool drop_flag_hi;

    Register<bit<1>, bit<1>>(1) flipflop_reg;
    RegisterAction<bit<1>, bit<1>, bit<1>>(flipflop_reg) get_flipflop = {
        void apply(inout bit<1> stored, out bit<1> returned) {
            if (stored == 1) {
                stored = 0;
                returned = 0;
            } else {
                stored = 1;
                returned = 1;
            }
        }
    };

    /* --------------------------------------------------------------------------------------
     *  Probabilistically set the drop flag based upon current fair rate threshold
     * -------------------------------------------------------------------------------------- */
    Register<drop_prob_pair_t, bit<1>>(1) drop_flag_calculator;
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_calculator) get_flip_drop_flag_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_hi to metadata1, set register_lo to metadata2
            if (stored_rng_vals.hi < drop_probability) {
                drop_decision = 1w1;
                stored_rng_vals.lo = rng_output
            } else {
                drop_decision = 1w0;
                stored_rng_vals.lo = rng_output
            }
        }
    };
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_calculator) get_flop_drop_flag_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_lo to metadata1, set register_hi to metadata2
            if (stored_rng_vals.lo < drop_probability) {
                drop_decision = 1w1;
                stored_rng_vals.hi = rng_output
            } else {
                drop_decision = 1w0;
                stored_rng_vals.hi = rng_output
            }
        }
    };

    /* --------------------------------------------------------------------------------------
     *  Pretend to probabilistically drop using fair_rate_lo as the current fair rate threshold
     * -------------------------------------------------------------------------------------- */
    Register<drop_prob_pair_t, bit<1>>(1) drop_flag_lo_calculator;
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_lo_calculator) get_flip_drop_flag_lo_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_hi to metadata1, set register_lo to metadata2
            if (stored_rng_vals.hi < drop_probability_lo) {
                drop_decision = 1w1;
                stored_rng_vals.lo = rng_output
            } else {
                drop_decision = 1w0;
                stored_rng_vals.lo = rng_output
            }
        }
    };
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_lo_calculator) get_flop_drop_flag_lo_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_lo to metadata1, set register_hi to metadata2
            if (stored_rng_vals.lo < drop_probability_lo) {
                drop_decision = 1w1;
                stored_rng_vals.hi = rng_output
            } else {
                drop_decision = 1w0;
                stored_rng_vals.hi = rng_output
            }
        }
    };

    /* --------------------------------------------------------------------------------------
     *  Pretend to probabilistically drop using fair_rate_hi as the current fair rate threshold
     * -------------------------------------------------------------------------------------- */
    Register<drop_prob_pair_t, bit<1>>(1) drop_flag_hi_calculator;
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_hi_calculator) get_flip_drop_flag_hi_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_hi to metadata1, set register_lo to metadata2
            if (stored_rng_vals.hi < drop_probability_hi) {
                drop_decision = 1w1;
                stored_rng_vals.lo = rng_output
            } else {
                drop_decision = 1w0;
                stored_rng_vals.lo = rng_output
            }
        }
    };
    RegisterAction<drop_prob_pair_t, bit<1>, bit<1>>(drop_flag_hi_calculator) get_flop_drop_flag_hi_regact = {
        void apply(inout drop_prob_pair_t stored_rng_vals, out bit<1> drop_decision) {
            // Compare register_lo to metadata1, set register_hi to metadata2
            if (stored_rng_vals.lo < drop_probability_hi) {
                drop_decision = 1w1;
                stored_rng_vals.hi = rng_output
            } else {
                drop_decision = 1w0;
                stored_rng_vals.hi = rng_output
            }
        }
    };


    /* --------------------------------------------------------------------------------------
     * Tables for calling the probabilistic drop registers
     * -------------------------------------------------------------------------------------- */
    bit<1> flipflop;
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
    table get_drop_flag() {
        key = {
            flipflop: exact;
        }
        actions = {
            get_flip_drop_flags;
            get_flop_drop_flags;
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
    table get_drop_flag_lo() {
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
    table get_drop_flag_hi() {
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
     * If this packet is going to actually be dropped, but fair_rate_lo or fair_rate_hi wouldn't have dropped it,
     * add the bytes of this packet to a per-slice byte store. The next non-dropped packet will pick up the bytes
     * and carry them to the egress rate estimators.
     * -------------------------------------------------------------------------------------- */
    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) byte_store_lo;
    RegisterAction<bytecount_t, bytecount_t, vlink_index_t>(byte_store_lo) grab_lo_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes + pkt_len;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, bytecount_t, vlink_index_t>(byte_store_lo) dump_lo_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            dumped_bytes = dumped_bytes + pkt_len;
            bytes_sent = 0;
        }
    };
    action grab_lo_bytes() {
        afd_md.bridged.lo_bytes_to_send = grab_lo_bytes_regact.execute(afd_md.bridged.vlink_id);
    }
    action dump_lo_bytes() {
        dump_lo_bytes_regact.execute(afd_md.bridged.vlink_id);
    }
    table dump_or_grab_lo_bytes {
        key = {
            drop_flag : exact;
            drop_flag_lo : exact;
        }
        actions = {
            dump_lo_bytes;
            grab_lo_bytes;
        }
        const entries = {
            (1, 0) : dump_lo_bytes();
            (0, 0) : grab_lo_bytes();
            (0, 1) : grab_lo_bytes();
            // (1,1) : no_action();
        }
    }
    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) byte_store_hi;
    RegisterAction<bytecount_t, bytecount_t, vlink_index_t>(byte_store_hi) grab_hi_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes + pkt_len;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, bytecount_t, vlink_index_t>(byte_store_hi) dump_hi_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            dumped_bytes = dumped_bytes + pkt_len;
            bytes_sent = 0;
        }
    };
    action grab_hi_bytes() {
        afd_md.bridged.hi_bytes_to_send = grab_hi_bytes_regact.execute(afd_md.bridged.vlink_id);
    }
    action dump_hi_bytes() {
        dump_hi_bytes_regact.execute(afd_md.bridged.vlink_id);
    }
    table dump_or_grab_hi_bytes {
        key = {
            drop_flag : exact;
            drop_flag_hi : exact;
        }
        actions = {
            dump_hi_bytes;
            grab_hi_bytes;
        }
        const entries = {
            (1, 0) : dump_hi_bytes();
            (0, 0) : grab_hi_bytes();
            (0, 1) : grab_hi_bytes();
            // (1,1) : no_action();
        }
    }


    /* --------------------------------------------------------------------------------------
     * Approximate the fair rates and measured rate as narrower integers for the lookup table
     * -------------------------------------------------------------------------------------- */
    // TODO: rshift action for every value in [0, 24]
	action rshift_8() {
        fair_rate_lo_shifted  = (shifted_rate_t) afd_md.fair_rate_lo  >> 8;
        fair_rate_shifted     = (shifted_rate_t) afd_md.fair_rate     >> 8;
        fair_rate_hi_shifted  = (shifted_rate_t) afd_md.fair_rate_hi  >> 8;
        measured_rate_shifted = (shifted_rate_t) afd_md.measured_rate >> 8;
	}
	action rshift_4() {
        fair_rate_lo_shifted  = (shifted_rate_t) afd_md.fair_rate_lo  >> 4;
        fair_rate_shifted     = (shifted_rate_t) afd_md.fair_rate     >> 4;
        fair_rate_hi_shifted  = (shifted_rate_t) afd_md.fair_rate_hi  >> 4;
        measured_rate_shifted = (shifted_rate_t) afd_md.measured_rate >> 4;
	}
	action rshift_2() {
        fair_rate_lo_shifted  = (shifted_rate_t) afd_md.fair_rate_lo  >> 2;
        fair_rate_shifted     = (shifted_rate_t) afd_md.fair_rate     >> 2;
        fair_rate_hi_shifted  = (shifted_rate_t) afd_md.fair_rate_hi  >> 2;
        measured_rate_shifted = (shifted_rate_t) afd_md.measured_rate >> 2;
	}
	action rshift_0() {
        fair_rate_lo_shifted  = (shifted_rate_t) afd_md.fair_rate_lo;
        fair_rate_shifted     = (shifted_rate_t) afd_md.fair_rate;
        fair_rate_hi_shifted  = (shifted_rate_t) afd_md.fair_rate_hi;
        measured_rate_shifted = (shifted_rate_t) afd_md.measured_rate;
	}
	table shift_measured_rate {
		key = {
            afd_md.measured_rate: ternary;
        }
		actions = {
            rshift_8;
            rshift_4;
            rshift_2;
            rshift_0;
        }
		default_action = rshift_0();
	}
    /* --------------------------------------------------------------------------------------
     * Lookup tables that map (i, j*) to int( 2**sizeof(drop_prob_t) * (1 - min(1, j* / i)))
     * for j* in {j, j_lo, j_hi}
     * -------------------------------------------------------------------------------------- */
    // Grab true drop probability
    action load_drop_prob_act(drop_prob_t prob) {
        drop_probability = prob;
    }
	table load_drop_prob {
		key = {
            fair_rate_shifted : exact;
            measured_rate_shifted: exact;
		}
		actions = {
            load_drop_prob_act;
        }
		default_action=load_drop_chance(0);
	}
    // Grab lo drop probability
    action load_drop_prob_lo_act(drop_prob_t prob) {
        drop_probability_lo = prob;
    }
	table load_drop_prob_lo {
		key = {
            fair_rate_lo_shifted : exact;
            measured_rate_shifted: exact;
		}
		actions = {
            load_drop_prob_lo_act;
        }
		default_action = load_drop_prob_lo_act(0);
	}
    // Grab hi drop probability
    action load_drop_prob_hi_act(drop_prob_t prob) {
        drop_probability_hi = prob;
    }
	table load_drop_prob_hi {
		key = {
            fair_rate_hi_shifted : exact;
            measured_rate_shifted: exact;
		}
		actions = {
            load_drop_prob_hi_act;
        }
		default_action=load_drop_prob_hi_act(0);
	}

	apply {
        // Approximate rates as narrower integers for use in the lookup tables
        shift_measured_rate.apply();
        // Lookup tables for true and simulated drop probabilities.
        // Each table is actually identical, but we need one copy for parallel computing of the three probabilities :(
        load_drop_prob.apply();
        load_drop_prob_lo.apply();
        load_drop_prob_hi.apply();
        
        rng_output = rng.get();
        flipflop = get_flipflop.execute(0);  // hack for easier comparisons using registers
        // Get true drop flag and simulated drop flags, by comparing
        //  lookup table outputs to an RNG value. If rng < output, mark to drop.
        get_drop_flag.apply();
        get_drop_flag_lo.apply();
        get_drop_flag_hi.apply();
        // Drop off or pick up packet bytecounts to allow the lo/hi drop simulations to work around true dropping.
        dump_or_grab_lo_bytes.apply();
        dump_or_grab_hi_bytes.apply();
	}
}

