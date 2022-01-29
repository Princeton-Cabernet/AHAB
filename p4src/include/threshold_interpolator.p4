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


    exponent_t remaining_lshift;
    byterate_t t_tmp;
    /*
     * The following includes will contain actions of the form
     * @hidden
     * action output_rshift_x() {
     *     t_tmp = div_result_mantissa >> x;
     * }
     * AND
     * @hidden
     * action output_lshift_x() {
     *     t_tmp = div_result_mantissa << x;
     * }
     */
#include "actions_and_entries/shift_lookup_output/action_defs.p4inc"
    action output_too_small() {
        // Call this action if div_result_mantissa would be rightshifted to oblivion
        t_tmp = 0;
    }

    table shift_lookup_output {
        // Do subtraction and shifting simultaenously via lookup table to avoid negatives and branching
        // Also saves 1-2 stages but thats not important yet
        key = {
            delta_t_log : exact;
            div_result_exponent : exact;
        }
        actions = {
#include "actions_and_entries/shift_lookup_output/action_list.p4inc"
            output_too_small;
        }
        default_action = output_too_small();
        const entries = {
#include "actions_and_entries/shift_lookup_output/const_entries.p4inc"
        }
        size = 512;
    }



#include "actions_and_entries/shift_lookup_output_stage2/action_defs.p4inc"
    table shift_lookup_output_stage2 {
        key = {
            remaining_lshift: exact;
        }
        actions = {
#include "actions_and_entries/shift_lookup_output_stage2/action_list.p4inc"
        }
        const entries = {
#include "actions_and_entries/shift_lookup_output_stage2/const_entries.p4inc"
        }
	size = 16;
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
        shift_lookup_output.apply();
        shift_lookup_output_stage2.apply();
        final_interpolation_result.apply();
    }
}


// Main for this file
control ThresholdInterpolator(in byterate_t vlink_rate,
                              in byterate_t vlink_rate_lo,
                              in byterate_t vlink_rate_hi,
                              in byterate_t target_rate, 
                              in byterate_t threshold, 
                              in byterate_t threshold_lo, 
                              in byterate_t threshold_hi,
                              in exponent_t candidate_delta_pow,
                              out byterate_t new_threshold) {
    
    // Difference between the three LPF outputs and the desired bitrate
    byterate_t target_minus_lo;
    byterate_t target_minus_mid;
    byterate_t target_minus_hi;


    InterpolationOp interp_op;
    byterate_t interp_numerator;
    byterate_t interp_denominator;


    @hidden
    action set_interpolate_left() {
        //precondition: rate_lo < *target* < rate_mid < rate_hi
        //postcondition: thres_mid - thres_delta < new_threshold < thres_mid
        interp_op = InterpolationOp.LEFT;
        interp_numerator   = vlink_rate         - target_rate;
        interp_denominator = vlink_rate         - vlink_rate_lo;
    }
    @hidden
    action set_interpolate_right() {
        //precondition: rate_lo < rate_mid < *target* < rate_hi
        //postcondition: thres_mid - thres_delta < new_threshold < thres_mid
        interp_op = InterpolationOp.RIGHT;
        interp_numerator   = target_rate        - vlink_rate;
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
#define TERNARY_NEG_CHECK 32w0x80000000 &&& 32w0x80000000
#define TERNARY_POS_CHECK 32w0 &&& 32w0x80000000
#define TERNARY_ZERO_CHECK 32w0 &&& 32w0xffffffff
#define TERNARY_DONT_CARE 32w0 &&& 32w0
    @hidden
    table choose_interpolation_action {
        key = {
            target_minus_lo : ternary;
            target_minus_mid : ternary;
            target_minus_hi : ternary;
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
            (TERNARY_ZERO_CHECK, TERNARY_ZERO_CHECK, TERNARY_DONT_CARE) : choose_middle_candidate();  // equal to low and mid
            (TERNARY_DONT_CARE,  TERNARY_ZERO_CHECK, TERNARY_ZERO_CHECK): choose_middle_candidate();  // equal to mid and high
            (TERNARY_DONT_CARE,  TERNARY_ZERO_CHECK, TERNARY_DONT_CARE) : choose_middle_candidate();  // equal to middle candidate
            (TERNARY_ZERO_CHECK, TERNARY_DONT_CARE,  TERNARY_DONT_CARE) : choose_low_candidate();     // equal to low candidate
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
            target_minus_lo  = target_rate - vlink_rate_lo;
            target_minus_mid = target_rate - vlink_rate;
            target_minus_hi  = target_rate - vlink_rate_hi;
            // Interpolate the new fair rate threshold
            choose_interpolation_action.apply();
            if (interp_op != InterpolationOp.NONE) {
                interpolate.apply(interp_numerator, interp_denominator, threshold,
                                  candidate_delta_pow, new_threshold, interp_op); 
            } 
    }
}
