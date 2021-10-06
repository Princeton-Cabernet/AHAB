from typing import Tuple, Dict, List

from matplotlib import pyplot as plt
from numpy import uint16
import math

MIN_RATIO = 2 ** -16  # if the true ratio is below this value, the lookup table stores 0


class TofinoNewtonStepper1:
    # Bit width of (c - c1) and (c2 - c1). Should be at least log_2(c2/c1)
    ratio_bits: int
    # Bit width of lookup table entries
    mantissa_bits: int
    # Value in [0,1) to add to lookup table inputs when computing lookup table outputs,
    #  to unbias the error caused by rounding the inputs
    lookup_rounding_unbias: float
    # Lookup table which maps (i,j) pairs to (i/j) in the form of a (mantissa, exponent) pair
    ratio_lookup: Dict[Tuple[int, int], Tuple[int, int]] = None  # lookup table

    def __init__(self,
                 ratio_bits: int,               # recommended 5-8
                 mantissa_bits: int,            # recommended 6-8
                 lookup_rounding_unbias: float  # recommended 0.5
                 ):
        self.ratio_lookup = dict()
        self.ratio_bits = ratio_bits
        self.mantissa_bits = mantissa_bits
        self.lookup_rounding_unbias = lookup_rounding_unbias
        self.populate_lookup_table()

    def populate_lookup_table(self):
        for i in range(2 ** self.ratio_bits):
            for j in range(1, 2 ** self.ratio_bits):
                # i and j will be rounded versions of more precise numbers.
                # To unbias the rounding error, we offset i and j slightly before computing their ratio
                ratio = (i + self.lookup_rounding_unbias) / (j + self.lookup_rounding_unbias)
                exp: int
                mantissa: int
                if ratio < MIN_RATIO:
                    exp = 0
                    mantissa = 0
                else:
                    exp = math.floor(math.log(ratio, 2)) - self.mantissa_bits + 1
                    mantissa = round(ratio * 2**(-exp))
                self.ratio_lookup[(i, j)] = (mantissa, exp)

    def get_threshold_from(self, c1: int, c2: int, t1: int, t2: int, c: int) -> int:
        """
        Compute a new threshold from two candidates and a target capacity.
        :param c1: Threshold candidate 1's traffic counter
        :param c2: Threshold candidate 2's traffic counter
        :param t1: Threshold candidate 1
        :param t2: Threshold candidate 2
        :param c:  The link capacity we are targeting with the new threshold
        :return: A new threshold T between T1 and T2 that would approximately permit `c` traffic
        """
        assert c2 > c1
        assert t2 > t1

        # For this approach, T2 - T1 should always be a power of 2
        delta_t = t2 - t1
        assert bin(delta_t).count('1') == 1
        delta_t_exp = int(math.log(delta_t, 2))

        numerator = c - c1
        denominator = c2 - c1

        # round the numerator and denominator for using as keys to the lookup table
        shift = denominator.bit_length() - self.ratio_bits
        num_shifted = numerator >> shift
        den_shifted = denominator >> shift

        ratio_mantissa, ratio_exp = self.ratio_lookup[(num_shifted, den_shifted)]
        output_shift = ratio_exp + delta_t_exp
        if output_shift > 0:
            return t1 + (ratio_mantissa << output_shift)
        return t1 + (ratio_mantissa >> -output_shift)


def print_quantiles(vals: List[float]):
    quantiles = [0.5, 0.9, 0.95, 0.99, 0.995, 0.999]
    vals_copy = vals.copy()
    vals_copy.sort()
    n = len(vals)
    print("Quantiles -- ", end="")
    for q in quantiles:
        print("%.3f: %.3f" % (q, vals_copy[int(n * q)]), end="")
    print("")


def plot_update_errors():
    ratio_bits = 7
    mantissa_bits = 8
    unbias = 0.5
    stepper = TofinoNewtonStepper1(ratio_bits=ratio_bits,
                                   mantissa_bits=mantissa_bits,
                                   lookup_rounding_unbias=unbias)

    fig, ax = plt.subplots()

    table_entries = (2 ** (stepper.ratio_bits*2))

    ax.set_title("Lookup table error. %d entries \n Ratio mantissa bits: %d, Ratio unbiasing: %.2f"
                 % (table_entries, stepper.mantissa_bits, stepper.lookup_rounding_unbias))
    ax.set_ylabel("(EstimatedT - TrueT) / TrueT")
    ax.set_xlabel("(C - C1) / (C2 - C1)")
    ax.yaxis.grid(color='gray', linestyle='dashed')

    for (c1, c2) in [(20000, 40000), (100000, 600000)]:
        for (t1, t2) in [(2048, 4096), (128, 256)]:
            errors = []
            capacities = list(range(c1+1, c2))
            for c in capacities:
                correct_t = int(t1 + ((c - c1) / (c2 - c1)) * (t2 - t1))
                lookup_t = stepper.get_threshold_from(c1, c2, t1, t2, c)
                errors.append((lookup_t - correct_t) / correct_t)

            x_vals = [(c - c1) / (c2 - c1) for c in capacities]

            line, = ax.plot(x_vals, errors, label="(%d, %d, %d, %d)" % (c1, c2, t1, t2), linewidth=1.0)

    ax.legend(title="(C1,C2,T1,T2)")
    plt.show()


plot_update_errors()

