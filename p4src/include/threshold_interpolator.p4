// Approx UPF. Copyright (c) Princeton University, all rights reserved

@hidden
enum bit<2> InterpolationOp {
    NONE = 0x0,
    LEFT = 0x1,
    RIGHT = 0x2
}


#define  INTERPOLATION_DIVISION_LOOKUP_TBL_SIZE 512
typedef bit<5> div_lookup_key_t;

// private control block, not called outside this file
control InterpolateFairRate(in byterate_t numerator, in byterate_t denominator, in byterate_t t_mid,
                            in exponent_t delta_t_log, out byterate_t t_new, in InterpolationOp interp_op) {
    // Calculates t_new = t_mid +- ( numerator / denominator ) * delta_t  // ( + if interp_right, - if interp_left)

    div_lookup_key_t shifted_numerator;    // always <= denominator
    div_lookup_key_t shifted_denominator;  // first bit always 1, use last 4 bits

    exponent_t div_result_exponent;
    byterate_t div_result_mantissa;

    /*
     * The following includes will contain actions of the form:
     * @hidden
     * action input_rshift_x() {
     *     shifted_numerator   = (div_lookup_key_t) (numerator >> x);
     *     shifted_denominator = (div_lookup_key_t) (denominator >> x);
     * }
     */
    action input_rshift_none() {
        shifted_numerator   = (div_lookup_key_t) numerator;
        shifted_denominator = (div_lookup_key_t) denominator;
    }
#include "actions_and_entries/shift_lookup_input/action_defs.p4inc"
    @hidden
    table shift_lookup_input {
        key = { denominator : ternary; }
        actions = {
#include "actions_and_entries/shift_lookup_input/action_list.p4inc"
            input_rshift_none;
        }
        size = 32;
        const entries = {
#include "actions_and_entries/shift_lookup_input/const_entries.p4inc"
        }
        default_action = input_rshift_none();
    }

    /*
     * The following includes will contain actions of the form
     * @hidden
     * action output_lshift_x() {
     *     t_new = div_result_mantissa << x;
     * }
     */
#include "actions_and_entries/lshift_lookup_output/action_defs.p4inc"
    @hidden
    table lshift_lookup_output {
        key = { div_result_exponent : exact; }
        actions = {
#include "actions_and_entries/lshift_lookup_output/action_list.p4inc"
        }
        size = 32;
        const entries = {
#include "actions_and_entries/lshift_lookup_output/const_entries.p4inc"
        }
    }


    /*
     * The following includes will contain actions of the form
     * @hidden
     * action output_rshift_x() {
     *     t_new = div_result_mantissa >> x;
     * }
     */
    @hidden
    action output_too_small() {
        // Call this action if div_result_mantissa would be rightshifted to oblivion
        t_new = 0;
    }
#include "actions_and_entries/rshift_lookup_output/action_defs.p4inc"
    @hidden
    table rshift_lookup_output {
        key = { div_result_exponent : exact; }
        actions = {
#include "actions_and_entries/rshift_lookup_output/action_list.p4inc"
            output_too_small;
        }
        default_action = output_too_small;
        size = 8;
        const entries = {
#include "actions_and_entries/rshift_lookup_output/const_entries.p4inc"
        }
    }




    action load_division_result(byterate_t mantissa, exponent_t neg_exponent) {
        div_result_mantissa = mantissa;
        div_result_exponent = neg_exponent; // indirect subtraction, see apply block
    }
    table approx_division_lookup {
        key={
            shifted_numerator: exact;
            shifted_denominator: exact;
        }
        actions = { load_division_result; }
        default_action=load_division_result(0, 0);
        size = INTERPOLATION_DIVISION_LOOKUP_TBL_SIZE;
        const entries = {
#include "actions_and_entries/approx_division_lookup/const_entries.p4inc"
        }
    }

    @hidden
    action final_interpolation_result_left() {
        t_new = t_mid - t_new;
    }
    @hidden
    action final_interpolation_result_right() {
        t_new = t_mid + t_new;
    }
    @hidden
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


    apply {
        shift_lookup_input.apply();
        approx_division_lookup.apply();
        // Two branches to avoid negatives
        if (delta_t_log > div_result_exponent) {
            div_result_exponent = delta_t_log - div_result_exponent;
            lshift_lookup_output.apply();
        }
        else {
            div_result_exponent = div_result_exponent - delta_t_log;
            rshift_lookup_output.apply();
        }

        final_interpolation_result.apply();
    }
}



// Main for this file
control ThresholdInterpolator(in bytecount_t scaled_pkt_len, in vlink_index_t vlink_id, 
                              in bytecount_t bytes_sent_lo, in bytecount_t bytes_sent_hi,
                              in byterate_t threshold, 
                              in byterate_t threshold_lo, in byterate_t threshold_hi,
                              in exponent_t candidate_delta_pow,
                              out byterate_t new_threshold) {

    // current_rate_lpf is the true transmitted bitrate
    // lo_ and hi_ are bitrates achieved by simulating lower and higher drop rates
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) current_rate_lpf;
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) lo_rate_lpf;
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) hi_rate_lpf;
    // Output of the LPFs
    byterate_t vlink_rate;
    byterate_t vlink_rate_lo;
    byterate_t vlink_rate_hi;
    
    // Difference between the three LPF outputs and the desired bitrate
    byterate_t drate;
    byterate_t drate_lo;
    byterate_t drate_hi;

    bit<1> dummy_bit = 0;
    @hidden
    action rate_act() {
        vlink_rate = (byterate_t) current_rate_lpf.execute(scaled_pkt_len, vlink_id);
    }
    @hidden
    table rate_tbl {
        key = { dummy_bit : exact; }
        actions = { rate_act; }
        const entries = { 0 : rate_act(); }
        size = 1;
    }
    @hidden
    action rate_lo_act() {
        vlink_rate_lo = (byterate_t) lo_rate_lpf.execute(bytes_sent_lo, vlink_id);
    }
    @hidden
    table rate_lo_tbl {
        key = { dummy_bit : exact; }
        actions = { rate_lo_act; }
        const entries = { 0 : rate_lo_act(); }
        size = 1;
    }
    @hidden
    action rate_hi_act() {
        vlink_rate_hi = (byterate_t) hi_rate_lpf.execute(bytes_sent_hi, vlink_id);
    }
    @hidden
    table rate_hi_tbl {
        key = { dummy_bit : exact; }
        actions = { rate_hi_act; }
        const entries = { 0 : rate_hi_act(); }
        size = 1;
    }


    InterpolationOp interp_op;
    byterate_t interp_numerator;
    byterate_t interp_denominator;


    @hidden
    action set_interpolate_left() {
        interp_op = InterpolationOp.LEFT;
        interp_numerator   = vlink_rate         - DESIRED_VLINK_RATE;
        interp_denominator = vlink_rate         - vlink_rate_lo;
    }
    @hidden
    action set_interpolate_right() {
        interp_op = InterpolationOp.RIGHT;
        interp_numerator   = DESIRED_VLINK_RATE - vlink_rate;
        interp_denominator = vlink_rate_hi      - vlink_rate;
    }
    @hidden
    action choose_middle_candidate() {
        interp_op = InterpolationOp.NONE;
        new_threshold = threshold;
    }
    @hidden
    action choose_low_candidate() {
        interp_op = InterpolationOp.NONE;
        new_threshold = threshold_lo;
    }
    @hidden
    action choose_high_candidate() {
        interp_op = InterpolationOp.NONE;
        new_threshold = threshold_hi;
    }

    
    // Width of these values is sizeof(byterate_t)
#define TERNARY_NEG_CHECK 32w0x70000000 &&& 32w0x70000000
#define TERNARY_POS_CHECK 32w0 &&& 32w0x70000000
#define TERNARY_ZERO_CHECK 32w0 &&& 32w0xffffffff
#define TERNARY_DONT_CARE 32w0 &&& 32w0
    @hidden
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

    InterpolateFairRate() interpolate;
    apply {
            rate_tbl.apply();
            rate_lo_tbl.apply();
            rate_hi_tbl.apply();
            // Get the slice's current rate, and the simulated rates based upon threshold_lo and threshold_hi
            drate = vlink_rate - DESIRED_VLINK_RATE;
            drate_lo = vlink_rate_lo - DESIRED_VLINK_RATE;
            drate_hi = vlink_rate_hi - DESIRED_VLINK_RATE;
            // Interpolate the new fair rate threshold
            choose_interpolation_action.apply();
            if (interp_op != InterpolationOp.NONE) {
                interpolate.apply(interp_numerator, interp_denominator, threshold,
                                  candidate_delta_pow, new_threshold, interp_op); 
            } 
    }
}
