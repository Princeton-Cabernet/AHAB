
/* TODO: THIS FILE
Save 2**k somewhere (the offset between T_lo and T_mid or T_mid and T_hi? Too expensive to compute it on-the-fly.
Can we load T_mid, T_low, T_high and 2**k all at once somewhere?
Load T_mid and 2**k, then compute T_low and T_high


*/

/* Interpolation:
 * Input is three points: (T_lo, R_lo), (T_mid, R_mid), (T_hi, R_hi)
 * If using (lo, mid), do T - dT. If using (mid, hi), do T + dT
 * How do we choose which points to use? compare R_desired to R_lo, R_mid, R_hi. R_desired is fixed (compile-time?)
 * Compare r_desired to each of r_lo, r_mid, r_hi. Get three bits out. Table maps all 3-bit combinations to interpolation actions
 *
 *
 */

enum bit<2> InterpolationOp {
    NONE = 0x0,
    LEFT = 0x1,
    RIGHT = 0x2
}

#define  INTERPOLATION_DIVISION_LOOKUP_TBL_SIZE 512
typedef bit<5> div_lookup_key_t;

// private control block, not called outside this file
control InterpolateFairRate(in bytecount_t numerator, in bytecount_t denominator, in bytecount_t t_mid,
                            in exponent_t delta_t_log, out bytecount_t t_new, in InterpolationOp interp_op) {
    // Calculates t_new = t_mid +- ( numerator / denominator ) * delta_t  // ( + if interp_right, - if interp_left)

    div_lookup_key_t shifted_numerator;    // always <= denominator
    div_lookup_key_t shifted_denominator;  // first bit always 1, use last 4 bits

    exponent_t div_result_exponent;
    bytecount_t div_result_mantissa;

    action input_rshift_4() {
        shifted_numerator   = (div_lookup_key_t) numerator >> 4;
        shifted_denominator = (div_lookup_key_t) denominator >> 4;
    }
    action input_rshift_0() {
        shifted_numerator   = (div_lookup_key_t) numerator >> 0;
        shifted_denominator = (div_lookup_key_t) denominator >> 0;
    }
    table shift_lookup_inputs {
        key = { denominator : ternary; }
        actions = {
            // TODO
            input_rshift_4;
            input_rshift_0;
        }
        default_action = input_rshift_0();
size = 32;
        //const entries = {
            // TODO
        //}
    }

    action output_lshift_4() {
        t_new = div_result_mantissa << 4;
    }
    action output_lshift_2() {
        t_new = div_result_mantissa << 2;
    }
    action output_lshift_0() {
        t_new = div_result_mantissa << 0;
    }
    table shift_lookup_output {
        key = { div_result_exponent : exact; }
        actions = {
            // TODO
            output_lshift_4;
            output_lshift_2;
            output_lshift_0;
        }
        default_action = output_lshift_0;
size = 32;
        //const entries = {
            // TODO
        //}
    }

    action load_division_result(bytecount_t mantissa, exponent_t exponent) {
        div_result_mantissa = mantissa;
        div_result_exponent = exponent + delta_t_log;
    }
    table approx_division_lookup {
        key={
            shifted_numerator: exact;
            shifted_denominator: exact;
        }
        actions = { load_division_result; }
        default_action=load_division_result(0, 0);
size = INTERPOLATION_DIVISION_LOOKUP_TBL_SIZE;
    }

    action final_interpolation_result_left() {
        t_new = t_mid - t_new;
    }
    action final_interpolation_result_right() {
        t_new = t_mid + t_new;
    }
    table final_interpolation_result {
        key = {
            interp_op : exact;
        }
        actions = {
            final_interpolation_result_left;
            final_interpolation_result_right;
        }
        const entries = {
            InterpolationOp.LEFT : final_interpolation_result_left();
            InterpolationOp.RIGHT : final_interpolation_result_right();
        }
        size = 2;
    }


    apply{
        shift_lookup_inputs.apply();
        approx_division_lookup.apply();
        shift_lookup_output.apply();
        final_interpolation_result.apply();
    }
}



// Main for this file
control ThresholdInterpolator(inout afd_metadata_t afd_md) {

    // current_rate_lpf is the true transmitted bitrate
    // lo_ and hi_ are bitrates achieved by simulating lower and higher drop rates
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) current_rate_lpf;
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) lo_rate_lpf;
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) hi_rate_lpf;
    // Output of the LPFs
    bytecount_t vlink_rate;
    bytecount_t vlink_rate_lo;
    bytecount_t vlink_rate_hi;
    
    // Difference between the three LPF outputs and the desired bitrate
    bytecount_t drate;
    bytecount_t drate_lo;
    bytecount_t drate_hi;

bit<1> dummy_bit = 0;
action rate_act() {
    vlink_rate = current_rate_lpf.execute(afd_md.scaled_pkt_len, afd_md.vlink_id);
}
table rate_tbl {
key = { dummy_bit : exact; }
actions = { rate_act; }
const entries = { 0 : rate_act(); }
size = 1;
}
action rate_lo_act() {
    vlink_rate_lo = lo_rate_lpf.execute(afd_md.bytes_sent_lo, afd_md.vlink_id);
}
table rate_lo_tbl {
key = { dummy_bit : exact; }
actions = { rate_lo_act; }
const entries = { 0 : rate_lo_act(); }
size = 1;
}
action rate_hi_act() {
    vlink_rate_hi = hi_rate_lpf.execute(afd_md.bytes_sent_hi, afd_md.vlink_id);
}
table rate_hi_tbl {
key = { dummy_bit : exact; }
actions = { rate_hi_act; }
const entries = { 0 : rate_hi_act(); }
size = 1;
}


    InterpolationOp interp_op;
    bytecount_t interp_numerator;
    bytecount_t interp_denominator;

    Register<epoch_t, vlink_index_t>(NUM_VLINKS) last_worker_epoch;
    RegisterAction<epoch_t, vlink_index_t, bit<1>>(last_worker_epoch) choose_to_work = {
        void apply(inout epoch_t stored_epoch, out bit<1> time_to_work) {
            if (stored_epoch == afd_md.epoch) {
                time_to_work = 1w0;
            } else {
                time_to_work = 1w1;
                stored_epoch = afd_md.epoch;
            }
        }
    };
action choose_to_work_act() {
    afd_md.is_worker = choose_to_work.execute(afd_md.vlink_id);
}
table choose_to_work_tbl {
key = { dummy_bit : exact; }
actions = { choose_to_work_act; }
const entries = { 0 : choose_to_work_act(); }
size = 1;
}



    action set_interpolate_left() {
        interp_op = InterpolationOp.LEFT;
        interp_numerator   = vlink_rate         - DESIRED_VLINK_RATE;
        interp_denominator = vlink_rate         - vlink_rate_lo;
    }
    action set_interpolate_right() {
        interp_op = InterpolationOp.RIGHT;
        interp_numerator   = DESIRED_VLINK_RATE - vlink_rate;
        interp_denominator = vlink_rate_hi      - vlink_rate;
    }
    action choose_middle_candidate() {
        interp_op = InterpolationOp.NONE;
        afd_md.new_threshold = afd_md.threshold;
    }
    action choose_low_candidate() {
        interp_op = InterpolationOp.NONE;
        afd_md.new_threshold = afd_md.threshold_lo;
    }
    action choose_high_candidate() {
        interp_op = InterpolationOp.NONE;
        afd_md.new_threshold = afd_md.threshold_hi;
    }

    
    // Width of these values is sizeof(bytecount_t)
#define TERNARY_NEG_CHECK 32w0x70000000 &&& 32w0x70000000
#define TERNARY_POS_CHECK 32w0 &&& 32w0x70000000
#define TERNARY_ZERO_CHECK 32w0 &&& 32w0xffffffff
#define TERNARY_DONT_CARE 32w0 &&& 32w0
    table choose_interpolation_action {
        key = {
            drate_lo : ternary;
            drate : ternary;
            drate_hi : ternary;
        }
        actions = {
            set_interpolate_left;
            set_interpolate_right;
            choose_middle_candidate;
            choose_low_candidate;
            choose_high_candidate;
        }
        const entries = {
            // The zero checks have to use "don't cares" for the other two candidates to not error on boundary cases,
            // because in boundary cases there may be two zero comparisons.
            // (In boundary cases either lo == mid or mid == hi)
            (TERNARY_ZERO_CHECK, TERNARY_DONT_CARE,  TERNARY_DONT_CARE) : choose_low_candidate();     // equal to low candidate
            (TERNARY_DONT_CARE,  TERNARY_ZERO_CHECK, TERNARY_DONT_CARE) : choose_middle_candidate();  // equal to middle candidate
            (TERNARY_DONT_CARE,  TERNARY_DONT_CARE,  TERNARY_ZERO_CHECK): choose_high_candidate();    // equal to high candidate

            (TERNARY_NEG_CHECK,  TERNARY_NEG_CHECK,  TERNARY_NEG_CHECK) : choose_low_candidate();     // below low candidate
            (TERNARY_POS_CHECK,  TERNARY_NEG_CHECK,  TERNARY_NEG_CHECK) : set_interpolate_left();     // between low and mid
            (TERNARY_POS_CHECK,  TERNARY_POS_CHECK,  TERNARY_NEG_CHECK) : set_interpolate_right();    // between mid and high
            (TERNARY_POS_CHECK,  TERNARY_POS_CHECK,  TERNARY_POS_CHECK) : choose_high_candidate();    // above high candidate
        }
size = 8;
        default_action = choose_middle_candidate();  // Something went wrong, stick with the current fair rate threshold
    }

    
    Register<bytecount_t, vlink_index_t>(size=NUM_VLINKS) winning_thresholds;
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(winning_thresholds) grab_new_threshold_regact = {
        void apply(inout bytecount_t stored, out bytecount_t retval) {
            retval = stored;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(winning_thresholds) dump_new_threshold_regact = {
        void apply(inout bytecount_t stored) {
            stored = afd_md.new_threshold;
        }
    };
    action grab_new_threshold() {
        afd_md.new_threshold = grab_new_threshold_regact.execute(afd_md.vlink_id);
    }
    action dump_new_threshold() {
        dump_new_threshold_regact.execute(afd_md.vlink_id);
    }
    table dump_or_grab_new_threshold {
        key = {
            afd_md.is_worker : exact;
        }
        actions = {
            dump_new_threshold;
            grab_new_threshold;
        }
        const entries = {
            0 : dump_new_threshold();
            1 : grab_new_threshold();
        }
size = 2;
    }

    InterpolateFairRate() interpolate;
    apply {
        if (afd_md.is_worker == 0) {
            rate_tbl.apply();
            rate_lo_tbl.apply();
            rate_hi_tbl.apply();
            // Get the slice's current rate, and the simulated rates based upon threshold_lo and threshold_hi
            drate = vlink_rate - DESIRED_VLINK_RATE;
            drate_lo = vlink_rate_lo - DESIRED_VLINK_RATE;
            drate_hi = vlink_rate_hi - DESIRED_VLINK_RATE;
            
            // Check if it is time to do some work
            choose_to_work_tbl.apply();
            // If it is time, interpolate the new fair rate threshold
            choose_interpolation_action.apply();
            if (interp_op != InterpolationOp.NONE) {
                interpolate.apply(interp_numerator, interp_denominator, afd_md.threshold,
                                  afd_md.candidate_delta_pow, afd_md.new_threshold, interp_op); 
            } 
        }

        dump_or_grab_new_threshold.apply();
        // (maybe save recirculation logic for main.p4?)
        // Recirculate the new fair rate threshold and the lo/hi candidates to all the ingress pipelines
    }
}
