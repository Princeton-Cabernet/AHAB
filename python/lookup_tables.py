import random

import math
from math import sqrt, ceil, floor, fabs
from typing import List, Callable, Dict, Tuple

import matplotlib.pyplot as plt

# Math unit constants
SIGNIFICAND_BITS = 4
LOOKUP_TABLE_LEN = 2 ** SIGNIFICAND_BITS  # number of entries in a math unit lookup table
LOOKUP_TABLE_ENTRY_WIDTH = 8  # size of a lookup table entry
REG_CELL_WIDTH = 32  # size of a register cell entry


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
        # Populate the lookup table
        for i in range(1 << num_significant_bits):
            for j in range(1 << num_significant_bits):
                # i and j will be rounded versions of more precise numbers.
                # To unbias the rounding error, we offset i and j slightly before dividing them
                value: int = round((i + unbiasing) * (j * unbiasing))
                self.table_entries[(i, j)] = value

    def multiply(self, a: int, b: int) -> int:
        assert a > 0 and b > 0
        # the exponent can be computed in tofino using TCAM lookup tables. If the operands are 32 bits,
        # the lookup tables will have 32 entries
        exponent: int = max(a.bit_length(), b.bit_length())
        rshift: int = exponent - self.num_significant_bits
        i = a >> rshift
        j = b >> rshift
        value = self.table_entries[(i, j)]
        return value << (2 * rshift)


class ApproxDivisionTable:
    """
    Division done using a lookup table instead of a math unit
    """
    table_entries: Dict[Tuple[int, int], Tuple[int, int]]
    num_significant_bits: int
    MIN_LOOKUP_ENTRY = 2 ** -16  # lookup entries smaller than this will be rounded down to 0

    def __init__(self, num_significant_bits: int, unbiasing: float = 0.5, lookup_value_mantissa_bits: int = 8):
        """
        Create a lookup table that approximately divides pairs of positive integers
        :param num_significant_bits: number of bits to preserve when approximating operands.
        Lookup table size will be 2 ** (2 * num_significant bits), so recommended values are <=8
        :param unbiasing: a value in the range [0,1) that is used to unbias lookup table error
        :param lookup_value_mantissa_bits: significant bits of division results stored in the lookup table
        """
        self.num_significant_bits = num_significant_bits
        # populate the lookup table
        for i in range(1 << num_significant_bits):
            for j in range(1 << num_significant_bits):
                # i and j will be rounded versions of more precise numbers.
                # To unbias the rounding error, we offset i and j slightly before dividing them
                value = (i + unbiasing) / (j + unbiasing)
                exp: int
                mantissa: int
                if value < self.MIN_LOOKUP_ENTRY:
                    exp = 0
                    mantissa = 0
                else:
                    exp = math.floor(math.log(value, 2)) - lookup_value_mantissa_bits + 1
                    mantissa = round(value * 2**(-exp))
                self.table_entries[(i, j)] = (mantissa, exp)

    def divide(self, a: int, b: int) -> float:
        assert a > 0 and b > 0

        exponent: int = max(a.bit_length(), b.bit_length())
        rshift: int = exponent - self.num_significant_bits
        i = a >> rshift
        j = b >> rshift

        mantissa, exponent = self.table_entries[(i,j)]

        return mantissa * (2 ** exponent)


class MathUnit:
    """
    A raw math unit, according to the barefoot SALU slide deck. Confusing as hell, good luck
    """
    exponent_shift: int
    exponent_invert: bool
    output_scale: int
    lookup_table: List[int]
    name: str

    def __init__(self, lookup_table: List[int], exponent_shift: int, exponent_invert: bool, output_scale: int,
                 name: str = "MathUnit"):
        """
        Create a simulated math unit with the provided parameters.
        :param lookup_table: A table containing 16 values for all possible 4-bit significands
        :param exponent_shift: How much the math unit should shift the input's exponent
        :param exponent_invert: Should the input's exponent be negated (as in exp becomes -exp)
        :param output_scale: The scale of the lookup table contents. Lookup table values will be multiplied by 2**scale
        """
        if exponent_shift > REG_CELL_WIDTH or exponent_shift < -REG_CELL_WIDTH:
            raise Exception("Exponent shift should be within (-%d,%d)" % (REG_CELL_WIDTH, REG_CELL_WIDTH))
        self.exponent_shift = exponent_shift
        self.exponent_invert = exponent_invert
        if output_scale > REG_CELL_WIDTH or output_scale < -REG_CELL_WIDTH:
            raise Exception("Output scale should be within (-%d,%d)" % (REG_CELL_WIDTH, REG_CELL_WIDTH))
        self.output_scale = output_scale
        if len(lookup_table) != LOOKUP_TABLE_LEN:
            raise Exception("Lookup table should have exactly %d entries but only %d were given"
                            % (LOOKUP_TABLE_LEN, len(lookup_table)))
        for entry in lookup_table:
            if entry < 0 or entry > 2 ** LOOKUP_TABLE_ENTRY_WIDTH:
                raise Exception("Lookup table entries should be %d bits wide!" % LOOKUP_TABLE_ENTRY_WIDTH)
        self.lookup_table = lookup_table.copy()
        self.name = name

    def compute(self, x: int):
        """
        The input x is approximated as (significand/2^3) * 2*exp, where `significand` is the 4 most-significant
        bits of x, and `exp` is the power of the most-significant bit of x.
        When calculating your lookup table values, you should take into account that all but the highest 4 bits are
        stripped by assuming the average-case for the discarded bits. For example, all values in [0x8000, 0x8fff]
        are mapped to the significand 0x8, so when you are calculating the lookup table value for 0x8,
        you should pretend the significand is actually 8.5. This helps reduce the output error (and reduces its bias)
        :param x:
        :return:
        """
        exponent = x.bit_length() - 1  # power of the most significant bit of x
        significand = int(bin(x)[2:2 + SIGNIFICAND_BITS], base=2)  # grab the 4 most significant bits of x
        new_exp: int
        if self.exponent_shift > 0:
            new_exp = exponent << self.exponent_shift
        else:
            new_exp = exponent >> (0 - self.exponent_shift)

        # Unclear from documentation if this inversion happens before or after the shifting. Placing after for now
        if self.exponent_invert:
            new_exp = -new_exp

        # significand is used as an index into the lookup table
        lookup_table_output = self.lookup_table[significand]

        output_shift = new_exp + self.output_scale
        if output_shift > 0:
            return lookup_table_output << output_shift
        return lookup_table_output >> -output_shift


class SquareMathUnit(MathUnit):
    def __init__(self, lookup_input_shift=0.5, **kwargs):
        lookup = [int((n + lookup_input_shift) ** 2) for n in range(16)]
        super(SquareMathUnit, self).__init__(lookup_table=lookup,
                                             exponent_shift=1,
                                             exponent_invert=False,
                                             output_scale=-6,
                                             **kwargs)




class SqrtMathUnit(MathUnit):
    def __init__(self, lookup_input_shift=0.5, **kwargs):
        """
        TODO: these parameters suck half the time. What does barefoot use?
        For x in (0, 16), find y in [0,256) and k s.t y/(2^k) ~ sqrt(x)
        y will be the lookup table value, and -k will be the output_scale.
        """
        lookup = [int(ceil(sqrt(n + lookup_input_shift) * 64)) for n in range(16)]
        super(SqrtMathUnit, self).__init__(lookup_table=lookup,
                                           exponent_shift=-1,
                                           exponent_invert=False,
                                           output_scale=-7,
                                           **kwargs)


class ConstMultMathUnit(MathUnit):
    """
    Should work fine for all real multiplicative factors in (0.0, 16.0]
    """
    def __init__(self, mult_factor, lookup_input_shift=0.5, **kwargs):
        largest_output = int(floor((15 + lookup_input_shift) * mult_factor))
        lookup_scale = 8 - largest_output.bit_length()
        lookup = [int((n + lookup_input_shift) * mult_factor * (2 ** lookup_scale)) for n in range(16)]
        output_scale = -lookup_scale - 3  # TODO: understand this -3 fully
        super(ConstMultMathUnit, self).__init__(lookup_table=lookup,
                                                exponent_shift=0,
                                                exponent_invert=False,
                                                output_scale=output_scale,
                                                **kwargs)


class EwmaRegister:
    sum_decayer: ConstMultMathUnit
    new_item_rshift: int  # how much to right-shift new items by before adding them to the moving average
    current_val: int
    ground_truth: float  # the actual EWMA value, as computed by python. used to determine error
    decay_factor: float  # equal to 1 - 2^-new_item_rshift. If new_item_rshift is 4, this is 15/16

    def __init__(self, new_item_rshift: int = 4, init_val: int = 0):
        self.new_item_rshift = new_item_rshift
        self.decay_factor = 1 - (2 ** (-new_item_rshift))
        self.sum_decayer = ConstMultMathUnit(mult_factor=self.decay_factor)
        self.current_val = init_val
        self.ground_truth = float(init_val)

    def update(self, x: int) -> int:
        update = x >> self.new_item_rshift
        self.current_val = self.sum_decayer.compute(self.current_val) + update
        self.ground_truth = (self.ground_truth * self.decay_factor) + update
        return self.current_val

    def current_error(self) -> float:
        if self.ground_truth == 0.0:
            if self.current_val != 0.0:
                return 1.0
            return 0.0
        return fabs(self.ground_truth - self.current_val) / self.ground_truth


"""
General idea for computing math unit lookup table entries:
Math unit input is approximated as (x/8) * 2^exp for x in [0,16)
The math unit will output (y/2^k) * 2^(exp + shift), where k and shift are fixed,
and y comes from an lookup table indexed by x. Think of k as the scale of the lookup table entries.
"""


def plot_relative_error(inputs: List[int], true_func: Callable[[int], float], func_str: str,
                        math_units: List[MathUnit]):
    fig, ax = plt.subplots()

    ax.set_title("Math unit relative error for %s" % func_str)
    ax.set_ylabel("Relative error (0.1 = 10%)")
    ax.set_xlabel("Input x to f(x)")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    for math_unit in math_units:
        errors = [(math_unit.compute(x) - true_func(x)) / max(true_func(x), 1) for x in inputs]
        line, = ax.plot(inputs, errors, label=math_unit.name, linewidth=1.0)

    ax.legend()
    plt.show()


def plot_multunit_error():
    #mult_factor = 15 / 16
    mult_factor = 11
    units = [ConstMultMathUnit(mult_factor=mult_factor, name="MultUnit")]
    # ConstMultMathUnit(mult_factor=mult_factor, lookup_input_shift=0.0, name="MultUnit-NoShift")]

    plot_relative_error(list(range(10, 65536)), lambda x: x * mult_factor,
                        "f(x) = x * %.3f" % mult_factor, units)


def plot_squareunit_error():
    units = [SquareMathUnit(name="SquareUnit")]
    # SquareMathUnit(name="SquareUnit-NoShift", lookup_input_shift=0.0)]
    plot_relative_error(list(range(10, 1<<20)), lambda x: pow(x, 2),
                        "f(x) = x^2", units)


def plot_sqrtunit_error():
    units = [SqrtMathUnit(name="SqrtUnit"),
             SqrtMathUnit(name="SqrtUnit-NoShift", lookup_input_shift=0.0)]
    plot_relative_error(list(range(10, 65536)), lambda x: pow(x, 0.5),
                        "f(x) = sqrt(x)", units)


def main4():
    # unit = SquareMathUnit()
    # func = lambda i: i**2
    mult_factor = 15 / 16
    unit = ConstMultMathUnit(mult_factor=mult_factor)
    func = lambda i: i * mult_factor
    for x in [500, 600, 700, 0x8fff]:
        fx = func(x)
        fpx = unit.compute(x)
        error = 100.0 * abs(fx - fpx) / fx
        print("x: %d, f(x): %d, math(x): %d, error: %.2f%%" % (x, fx, fpx, error))


def main5():
    ewma = EwmaRegister(new_item_rshift=5)
    errors = []
    vals = []
    for _ in range(30):
        val = random.randint(int(1e5), int(1e8))
        vals.append(val)
        ewma.update(val)
        errors.append("%.2f%%" % (ewma.current_error() * 100))
    errors.append("HIJACK")
    vals.append("HIJACK")
    for _ in range(30):
        val = random.randint(int(1e8), int(1e10))
        vals.append(val)
        ewma.update(val)
        errors.append("%.2f%%" % (ewma.current_error() * 100))
    print("Latency measurements:", vals)
    print("EWMA errors:", errors)


def plot_lookup_mult_error():
    table = ApproxMultiplicationTable(num_significant_bits=5)
    #mult_factor = 15 / 16
    mult_factor = 11
    units = [ConstMultMathUnit(mult_factor=mult_factor, name="MultUnit")]
    # ConstMultMathUnit(mult_factor=mult_factor, lookup_input_shift=0.0, name="MultUnit-NoShift")]

    plot_relative_error(list(range(10, 65536)), lambda x: x * mult_factor,
                        "f(x) = x * %.3f" % mult_factor, units)


if __name__ == "__main__":
    #plot_multunit_error()
    main5()
