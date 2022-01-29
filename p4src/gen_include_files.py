#!/usr/bin/python3
import math
import os
from typing import Tuple

base_dir = "./include/actions_and_entries/"

interp_input_precision = 5
interp_output_precision = 8
bitwidth_of_byterate_t = 32
drop_rate_input_precision = 6
drop_rate_output_precision = 16
max_drop_probability = (1 << drop_rate_output_precision) - 2
simulated_drop_rate_input_precision = 5
sim_real_drop_precision_diff = drop_rate_input_precision - simulated_drop_rate_input_precision

fname_actionlist = "action_list.p4inc"
fname_actiondefs = "action_defs.p4inc"
fname_const_entries = "const_entries.p4inc"

dir_shift_lookup_input = "shift_lookup_input/"
dir_shift_lookup_output = "shift_lookup_output/"
dir_shift_lookup_output_stage2 = "shift_lookup_output_stage2/"
dir_shift_measured_rate = "shift_measured_rate/"
dir_drop_probability = "load_drop_prob/"
dir_approx_division = "approx_division_lookup/"


def gen_actiondef(action_namef: str, action_bodyf: str, shiftnum: int, param_str: str = "") -> str:
    stringf = "".join(["\n", "action ", action_namef, "(", param_str, ") {{\n", action_bodyf, "\n}}\n"])
    shiftnum_occurrences = stringf.count("{}")
    shiftnums = (shiftnum,) * shiftnum_occurrences
    return stringf.format(*shiftnums)


def gen_actiondef_multiparam(action_namef: str, action_bodyf: str, shiftnums: Tuple[int], param_str: str = "") -> str:
    stringf = "".join(["\n", "action ", action_namef, "(", param_str, ") {{\n", action_bodyf, "\n}}\n"])
    shiftnum_occurrences = stringf.count("{}")
    if shiftnum_occurrences != len(shiftnums):
        raise Exception("Bad number of parameters given to gen_actiondef_multiparam. %d given, %d expected" 
                % (len(shiftnums), shiftnum_occurrences))
    return stringf.format(*shiftnums)


ONES_32 = 0xffffffff
hex32f = "0x{:0>8x}"


def get_ternary_match_key(val: int, mask: int) -> str:
    return "".join(["(", hex32f, " &&& ", hex32f, ")"]).format(val, mask)


def get_match_key_leftmost_bit(bit_pos: int) -> str:
    """ NOTE: bit_pos is 0-indexed. bit_pos == 0 is the right-most bit. 
    """
    assert (0 < bit_pos <= 31)
    mask = (ONES_32 << bit_pos) & ONES_32
    val = 1 << bit_pos
    return get_ternary_match_key(val, mask)


def gen_files__shift_lookup_input():
    """
    Table shift_lookup_inputs that creates input keys to the fair rate threshold interpolator
    """
    max_shift = bitwidth_of_byterate_t - interp_input_precision - 1
    min_shift = 0
    action_namef = "input_rshift_{}"
    action_bodyf = "    shifted_numerator   = (div_lookup_key_t) (numerator >> {});\n" \
                   "    shifted_denominator = (div_lookup_key_t) (denominator >> {});"

    dir_name = base_dir + dir_shift_lookup_input
    os.makedirs(os.path.dirname(dir_name), exist_ok=True)

    with open(dir_name + fname_actiondefs, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            fp.write(gen_actiondef(action_namef, action_bodyf, shift))

    with open(dir_name + fname_actionlist, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            fp.write(action_namef.format(shift) + ";\n")

    with open(dir_name + fname_const_entries, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            # if leftmost bit is at position interp_input_precision + k - 1, rshift by k
            # if rshifting by k, check for leftmost bit at interp_input_precision + k - 1
            bit_pos = shift + interp_input_precision - 1
            match_key = get_match_key_leftmost_bit(bit_pos)
            action_string = action_namef.format(shift)
            fp.write("{} : {}();\n".format(match_key, action_string))


num_second_shifts = 8


def gen_files__shift_lookup_output():
    """
    Table shift_lookup_output that computes the new fair rate threshold
    """
    max_lshift = 31
    min_lshift = 1
    action_l_namef = "output_lshift_{}"
    action_l_bodyf = "    t_tmp = div_result_mantissa << {};\n"\
                     "    remaining_lshift = remaining_lshift_param;"

    max_rshift = interp_output_precision
    min_rshift = 0
    action_r_namef = "output_rshift_{}"
    action_r_bodyf = "    t_tmp = div_result_mantissa >> {};\n" \
                     "    remaining_lshift = 0;"

    first_lshifts = list(range(min_lshift, max_lshift+1, num_second_shifts))

    dir_name = base_dir + dir_shift_lookup_output
    os.makedirs(os.path.dirname(dir_name), exist_ok=True)

    with open(dir_name + fname_actiondefs, 'w') as fp:
        for shift in first_lshifts:
            fp.write(gen_actiondef(action_l_namef, action_l_bodyf, shift,
                                   param_str="exponent_t remaining_lshift_param"))
        for shift in range(min_rshift, max_rshift+1):
            fp.write(gen_actiondef(action_r_namef, action_r_bodyf, shift))

    with open(dir_name + fname_actionlist, 'w') as fp:
        for shift in first_lshifts:
            fp.write(action_l_namef.format(shift) + ";\n")
        for shift in range(min_rshift, max_rshift+1):
            fp.write(action_r_namef.format(shift) + ";\n")

    with open(dir_name + fname_const_entries, 'w') as fp:
        for delta_t_log in range(0, 32):
            for div_result_exponent in range(0, 10):
                exponent = delta_t_log - div_result_exponent
                action_param = ""
                action_name = ""
                if exponent > 0:
                    first_shift = max([x for x in first_lshifts if x <= exponent])
                    second_shift = exponent - first_shift
                    action_name = action_l_namef.format(first_shift)
                    action_param = str(second_shift)
                elif exponent <= 8:
                    continue  # result will be too small
                else:
                    action_name = action_r_namef.format(-exponent)
                fp.write("({}, {}) : {}({});\n".format(str(delta_t_log), str(div_result_exponent),
                                                       action_name, action_param))


def gen_files__shift_lookup_output_stage2():
    """
    Table shift_lookup_output_stage2 that finishes off the shifting started by shift_lookup_output
    """
    max_shift = num_second_shifts - 1
    min_shift = 1
    action_namef = "output_stage2_rshift_{}"
    action_bodyf = "    t_new = t_tmp << {};"

    dir_name = base_dir + dir_shift_lookup_output_stage2
    os.makedirs(os.path.dirname(dir_name), exist_ok=True)

    with open(dir_name + fname_actiondefs, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            fp.write(gen_actiondef(action_namef, action_bodyf, shift))

    with open(dir_name + fname_actionlist, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            fp.write(action_namef.format(shift) + ";\n")

    with open(dir_name + fname_const_entries, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            fp.write("{} : {}();\n".format(str(shift), action_namef.format(shift)))


def gen_files__shift_measured_rate():
    """
    Table shift_measured_rate in rate enforcement
    """
    max_shift = bitwidth_of_byterate_t - drop_rate_input_precision - 1
    min_shift = 0
    action_namef = "rshift_{}"
    action_bodyf = "    threshold_lo_shifted  = (shifted_rate_t) (threshold_lo   >> {});\n" \
                   "    threshold_hi_shifted  = (shifted_rate_t) (threshold_hi   >> {});\n" \
                   "    measured_rate_shifted = (shifted_rate_t) (measured_rate  >> {});\n" \
                   "    threshold_mid_shifted     = (shifted_mid_rate_t) (threshold_mid  >> {});\n" \
                   "    measured_rate_mid_shifted = (shifted_mid_rate_t) (measured_rate  >> {});"

    dir_name = base_dir + dir_shift_measured_rate
    os.makedirs(os.path.dirname(dir_name), exist_ok=True)

    with open(dir_name + fname_actiondefs, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            fp.write(gen_actiondef_multiparam(action_namef, action_bodyf, 
                   (shift, 
                    shift + sim_real_drop_precision_diff, 
                    shift + sim_real_drop_precision_diff, 
                    shift + sim_real_drop_precision_diff, 
                    shift, 
                    shift)))

    with open(dir_name + fname_actionlist, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            fp.write(action_namef.format(shift) + ";\n")

    with open(dir_name + fname_const_entries, "w") as fp:
        for shift in range(min_shift, max_shift+1):
            # if leftmost bit is at position bitwidth + k - 1, rshift by k
            # if rshifting by k, check for leftmost bit at bitwidth + k - 1
            bit_pos = shift + drop_rate_input_precision - 1
            match_key = get_match_key_leftmost_bit(bit_pos)
            action_string = action_namef.format(shift)
            fp.write("{} : {}();\n".format(match_key, action_string))


def gen_files__drop_prob_lookup():
    """
    Three drop probability lookup tables for threshold, threshold_lo, threshold_hi
    """
    dir_name = base_dir + dir_drop_probability
    os.makedirs(os.path.dirname(dir_name), exist_ok=True)
    entryf = "({:>3}, {:>3}) : load_drop_prob{}_act({:>3});\n"
    for suffix in ["_lo", "_hi"]:
        with open(dir_name + "const_entries" + suffix + ".p4inc", 'w') as fp:
            for denominator in range(1 << (simulated_drop_rate_input_precision - 1), 1 << simulated_drop_rate_input_precision):
                for numerator in range(denominator + 1):
                    drop_rate = 1 - (numerator / denominator)
                    drop_probability = round(((1 << drop_rate_output_precision) - 1) * drop_rate)
                    drop_probability = min(max_drop_probability, drop_probability)
                    fp.write(entryf.format(numerator, denominator, suffix, drop_probability))
    for suffix in ["_mid"]:
        with open(dir_name + "const_entries" + suffix + ".p4inc", 'w') as fp:
            for denominator in range(1 << (drop_rate_input_precision - 1), 1 << drop_rate_input_precision):
                for numerator in range(denominator + 1):
                    drop_rate = 1 - (numerator / denominator)
                    drop_probability = round(((1 << drop_rate_output_precision) - 1) * drop_rate)
                    drop_probability = min(max_drop_probability, drop_probability)
                    fp.write(entryf.format(numerator, denominator, suffix, drop_probability))


def gen_files__approx_division_lookup():
    """
    Approximate division lookup table for new threshold interpolation.
    """
    dir_name = base_dir + dir_approx_division
    os.makedirs(os.path.dirname(dir_name), exist_ok=True)
    entryf = "({:>3}, {:>3}) : load_division_result({:>3}, {:>3});\n"
    minimum_interp_lookup_entry = 2 ** -16
    with open(dir_name + fname_const_entries, 'w') as fp:
        for denominator in range(1 << (interp_input_precision - 1), 1 << interp_input_precision):
            for numerator in range(denominator + 1):
                quotient = (numerator + 0.5) / (denominator + 0.5)
                exponent: int
                mantissa: int
                if quotient < minimum_interp_lookup_entry:
                    exponent = 0
                    mantissa = 0
                else:
                    # TODO: is this exponent calculation right? should interp_output_precision be here?
                    exponent = math.floor(math.log(quotient, 2)) - interp_output_precision + 1
                    mantissa = round(quotient * 2**(-exponent))
                if mantissa >= (1 << interp_output_precision):
                    print("WARNING: mantissa too large when dividing {} and {}".format(numerator, denominator))
                fp.write(entryf.format(numerator, denominator, mantissa, -exponent))


# TODO: add function for generating a file of threshold delta lookup const entries, instead of having them inline


def main():
    gen_files__shift_lookup_input()
    gen_files__shift_lookup_output()
    gen_files__shift_lookup_output_stage2()
    gen_files__shift_measured_rate()
    gen_files__drop_prob_lookup()
    gen_files__approx_division_lookup()


if __name__ == "__main__":
    main()
