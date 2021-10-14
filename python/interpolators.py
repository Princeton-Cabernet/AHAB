from abc import ABC, abstractmethod
from typing import Tuple, Dict, List

from matplotlib import pyplot as plt
from numpy import uint16
import math


class ThresholdInterpolator(ABC):
    @abstractmethod
    def interpolate(self, t1: int, t2: int, c1: int, c2: int, c: int) -> int:
        """
        Compute a new threshold from two candidates and a target capacity.
        :param t1: Threshold candidate 1
        :param t2: Threshold candidate 2
        :param c1: Threshold candidate 1's traffic counter
        :param c2: Threshold candidate 2's traffic counter
        :param c:  The link capacity we are targeting with the new threshold
        :return: A new threshold T between t1 and t2 that would approximately permit `c` traffic
        """
        return NotImplemented


class ExactThresholdInterpolator(ThresholdInterpolator):
    def interpolate(self, t1: int, t2: int, c1: int, c2: int, c: int) -> int:
        return int(t1 + ((c - c1) / (c2 - c1)) * (t2 - t1))


class TofinoThresholdInterpolator(ThresholdInterpolator):
    # Bit width of (c - c1) and (c2 - c1) after rounding. Should be at least log_2(c2/c1)
    ratio_bits: int
    # Bit width of lookup table entries
    mantissa_bits: int
    # Value in [0,1) to add to lookup table inputs when computing lookup table outputs,
    #  to unbias the error caused by rounding the inputs
    lookup_rounding_unbias: float
    # Lookup table which maps (i,j) pairs to (i/j) in the form of a (mantissa, exponent) pair
    ratio_lookup: Dict[Tuple[int, int], Tuple[int, int]] = None  # lookup table
    # When computing lookup table entries, if the true value is smaller than this, 0 is stored instead
    MIN_LOOKUP_ENTRY = 2 ** -16

    def __init__(self,
                 ratio_bits: int = 7,                   # recommended 5-8
                 mantissa_bits: int = 8,                # recommended 6-8
                 lookup_rounding_unbias: float = 0.5    # recommended 0.5
                 ):
        self.ratio_lookup = dict()
        self.ratio_bits = ratio_bits
        self.mantissa_bits = mantissa_bits
        self.lookup_rounding_unbias = lookup_rounding_unbias
        self.populate_lookup_table()

    def lookup_table_size(self):
        return len(self.ratio_lookup)

    def populate_lookup_table(self):
        for j in range(1 << (self.ratio_bits - 1), 1 << self.ratio_bits):
            for i in range(j+1):
                # i and j will be rounded versions of more precise numbers.
                # To unbias the rounding error, we offset i and j slightly before computing their ratio
                ratio = (i + self.lookup_rounding_unbias) / (j + self.lookup_rounding_unbias)
                exp: int
                mantissa: int
                if ratio < self.MIN_LOOKUP_ENTRY:
                    exp = 0
                    mantissa = 0
                else:
                    exp = math.floor(math.log(ratio, 2)) - self.mantissa_bits + 1
                    mantissa = round(ratio * 2**(-exp))
                self.ratio_lookup[(i, j)] = (mantissa, exp)

    def interpolate(self, t1: int, t2: int, c1: int, c2: int, c: int) -> int:
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
        num_shifted = numerator >> shift if shift > 0 else numerator << -shift
        den_shifted = denominator >> shift if shift > 0 else denominator << -shift

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
    stepper = TofinoThresholdInterpolator(ratio_bits=ratio_bits,
                                          mantissa_bits=mantissa_bits,
                                          lookup_rounding_unbias=unbias)

    fig, ax = plt.subplots()

    ax.set_title("Lookup table error. %d per-key bits, %d entries \n Lookup entry mantissa bits: %d, "
                 "Lookup entry unbiasing: %.2f "
                 % (stepper.ratio_bits,
                    stepper.lookup_table_size(),
                    stepper.mantissa_bits,
                    stepper.lookup_rounding_unbias))
    ax.set_ylabel("(EstimatedT - TrueT) / TrueT")
    ax.set_xlabel("(C - C1) / (C2 - C1)")
    ax.yaxis.grid(color='gray', linestyle='dashed')

    for (c1, c2) in [(20000, 40000), (100000, 600000)]:
        for (t1, t2) in [(2048, 4096), (128, 256)]:
            errors = []
            capacities = list(range(c1+1, c2))
            for c in capacities:
                correct_t = int(t1 + ((c - c1) / (c2 - c1)) * (t2 - t1))
                lookup_t = stepper.interpolate(t1, t2, c1, c2, c)
                errors.append((lookup_t - correct_t) / correct_t)

            x_vals = [(c - c1) / (c2 - c1) for c in capacities]

            line, = ax.plot(x_vals, errors, label="(%d, %d, %d, %d)" % (c1, c2, t1, t2), linewidth=1.0)

    ax.legend(title="(C1,C2,T1,T2)")
    plt.show()


if __name__ == "__main__":
    plot_update_errors()
