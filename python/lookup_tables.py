from typing import List, Callable, Dict, Tuple, Union

import math
import matplotlib.pyplot as plt
import numpy as np


class ApproxMultiplicationTable:
    """
    Multiplication done using a lookup table instead of a math unit
    """
    table_entries: Dict[Tuple[int, int], int]
    num_significant_bits: int

    def __init__(self, num_significant_bits: int, unbiasing: float = 0.5):
        """
        Create a lookup table that approximately multiplies pairs of positive integers
        :param num_significant_bits: number of bits to preserve when approximating operands.
        Lookup table size will be 2 ** (2 * num_significant bits), so recommended values are <=8
        :param unbiasing: a value in the range [0,1) that is used to unbias lookup table error
        """
        self.num_significant_bits = num_significant_bits
        self.table_entries = {}
        # Populate the lookup table
        for i in range(1 << num_significant_bits):
            for j in range(1 << num_significant_bits):
                # i and j will be rounded versions of more precise numbers.
                # To unbias the rounding error, we offset i and j slightly before dividing them
                value: int = round((i + unbiasing) * (j + unbiasing))
                self.table_entries[(i, j)] = value

    def compute(self, a: int, b: int) -> int:
        assert a > 0 and b > 0
        # the exponent can be computed in tofino using TCAM lookup tables. If the operands are 32 bits,
        # the lookup tables will have 32 entries
        exponent: int = max(a.bit_length(), b.bit_length())
        rshift: int = max(exponent - self.num_significant_bits, 0)
        i = a >> rshift
        j = b >> rshift
        value = self.table_entries[(i, j)]
        return value << (2 * rshift)

    def table_size(self) -> int:
        return len(self.table_entries)


class ApproxDivisionTable:
    """
    Division done using a lookup table instead of a math unit
    """
    table_entries: Dict[Tuple[int, int], Tuple[int, int]]
    num_significant_bits: int
    MIN_LOOKUP_OUTPUT = 2 ** -16  # lookup entries smaller than this will be rounded down to 0
    min_denominator: int

    def __init__(self, num_significant_bits: int, unbiasing: float = 0.5, lookup_value_mantissa_bits: int = 8):
        """
        Create a lookup table that approximately divides pairs of positive integers
        :param num_significant_bits: number of bits to preserve when approximating operands.
        Lookup table size will be 2 ** (2 * num_significant bits), so recommended values are <=8
        :param unbiasing: a value in the range [0,1) that is used to unbias lookup table error
        :param lookup_value_mantissa_bits: significant bits of division results stored in the lookup table
        """
        self.num_significant_bits = num_significant_bits
        self.table_entries = {}
        # populate the lookup table
        self.min_denominator = 1 << (num_significant_bits - 1)
        for j in range(1 << (num_significant_bits - 1), 1 << num_significant_bits):
            for i in range(1, j + 1):
                # i and j will be rounded versions of more precise numbers.
                # To unbias the rounding error, we offset i and j slightly before dividing them
                value = (i + unbiasing) / (j + unbiasing)
                exp: int
                mantissa: int
                if value < self.MIN_LOOKUP_OUTPUT:
                    exp = 0
                    mantissa = 0
                else:
                    exp = math.floor(math.log(value, 2)) - lookup_value_mantissa_bits + 1
                    mantissa = round(value * 2 ** (-exp))
                self.table_entries[(i, j)] = (mantissa, exp)

    def compute(self, a: int, b: int) -> float:
        assert a > 0 and b > 0

        # inputs are too small, scale them up
        if b < self.min_denominator:
            b_bits = b.bit_length()
            lshift = self.num_significant_bits - b_bits
            b = b << lshift
            a = a << lshift

        exponent: int = max(a.bit_length(), b.bit_length())
        rshift: int = exponent - self.num_significant_bits
        i = a >> rshift
        j = b >> rshift
        if i == 0:
            return self.MIN_LOOKUP_OUTPUT

        mantissa, exponent = self.table_entries[(i, j)]

        return mantissa * (2 ** exponent)

    def table_size(self) -> int:
        return len(self.table_entries)


def plot_relative_error(a_vals: List[int], b_vals: List[int],
                        true_func: Callable[[int, int], float],
                        lookup: Union[ApproxMultiplicationTable, ApproxDivisionTable]):
    fig, ax = plt.subplots()

    ax.set_title("Relative error for %s with %d entries" % (type(lookup).__name__, lookup.table_size()))
    ax.set_ylabel("Relative error (0.1 = 10%)")
    ax.set_xlabel("Input a to f(a,b)")

    for b in b_vals:
        errors = []
        for a in a_vals:
            true_result = true_func(a, b)
            if a > b:
                approx_result = true_result
            else:
                approx_result = lookup.compute(a, b)
            error = (approx_result - true_result) / true_result
            errors.append(error)

        line, = ax.plot(a_vals, errors, label="%d" % b, linewidth=1.0)

    ax.legend(title="Input b to f(a,b)")
    plt.show()


def sweep_division_inputs(lowest_bitcount=5, highest_bitcount=7, highest_input=100000):
    for bitcount in range(lowest_bitcount, highest_bitcount + 1):
        for unbiasing in [0.0, 0.5]:
            div_lookup = ApproxDivisionTable(num_significant_bits=bitcount, unbiasing=unbiasing)
            errors = []
            step_size = highest_input // 10
            higherest_input = highest_input + step_size
            for denominator in range(1, higherest_input, step_size):
                for numerator in range(1, denominator + 1):
                    approx_result = div_lookup.compute(numerator, denominator)
                    true_result = numerator / denominator
                    relative_error = abs((approx_result - true_result) / true_result)
                    #if relative_error == 1:
                    #    print(numerator, denominator)
                    errors.append(relative_error)
            mean_error = np.mean(errors)
            del errors
            print("Input bitwidth: {}, Unbiasing: {}, Mean error: {}, Num Entries: {}".format(
                bitcount, unbiasing, mean_error, len(div_lookup.table_entries)))


def main():
    a_vals = [i for i in range(100000, 500000)]
    b_vals = [j for j in range(100000, 500000, 100000)]
    mult_lookup = ApproxMultiplicationTable(num_significant_bits=7)
    div_loookup = ApproxDivisionTable(num_significant_bits=6)
    # plot_relative_error(a_vals, b_vals, lambda a, b: a * b, mult_lookup)
    # plot_relative_error(a_vals, b_vals, lambda a, b: a / b, div_loookup)
    sweep_division_inputs()


if __name__ == "__main__":
    main()
