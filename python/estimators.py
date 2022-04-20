from abc import ABC, abstractmethod
from functools import partial
from typing import List, Optional, Callable, Tuple

import math
from numpy import argmax

from common import bytes_accepted, LPF_DECAY, LPF_SCALE
from interpolators import ThresholdInterpolator, TofinoThresholdInterpolator, ExactThresholdInterpolator
from rate_estimators import LpfSingleton


def binary_search_for_input(desired_output: int, input_lo: int, input_hi: int,
                            func: Callable[[int], int]):
    """
    Find (and return) the lowest input that makes function `func` produce `desired_output`,
     OR the highest input that produces output lower than `desired_output` if no input can exactly produce the output
    :param desired_output: The output we desire from function `func`
    :param input_lo: The high end of the input range
    :param input_hi: The low end of the input range
    :param func: The function
    :return: The input, between `input_lo` and `input_hi`, that makes `func` produce `desired_output`
    """
    # Find the highest input that gives an output less than or equal to the desired output
    assert (input_hi > input_lo)
    output_hi = func(input_hi)
    output_lo = func(input_lo)
    assert (output_hi >= output_lo)
    assert (desired_output >= output_lo)
    if output_hi < desired_output:
        return input_hi
    input_arg = int((input_lo + input_hi) / 2)
    output = func(input_arg)
    while True:
        # print("Curr: %d, Lo: %d, Hi: %d, Desired: %d, Found: %d"
        #      % (input_arg, input_lo, input_hi, desired_output, output))
        new_input_arg: int
        if output > desired_output:
            # output too high
            input_hi = input_arg - 1  # exclude the too-high input
            new_input_arg = math.floor((input_lo + input_arg) / 2)
        elif output == desired_output:
            # output correct. We still want to see if we can find a lower input with the correct output
            input_hi = input_arg
            new_input_arg = math.floor((input_lo + input_arg) / 2)
        else:
            # output too low, but this may be the best we can do, so don't exclude the input
            input_lo = input_arg
            new_input_arg = math.ceil((input_arg + input_hi) / 2)
        if input_hi <= input_lo + 1:
            # print("Pointers converged. Lo: %d, Hi: %d" % (input_lo, input_hi))
            return input_hi
        if new_input_arg == input_arg:
            raise Exception("BUG: binary search got stuck. Lo: %d, Hi: %d, curr: %d, output: %d, desired: %d"
                            % (input_lo, input_hi, input_arg, output, desired_output))
        input_arg = new_input_arg
        output = func(input_arg)


def speculative_threshold(true_flow_rates: List[int], link_capacity: int) -> int:
    """ A threshold that gives the largest flow sufficient space to grow to fill the link.
    """
    sum_of_rates = sum(true_flow_rates)
    largest_rate = max(true_flow_rates)
    spare_capacity = max(link_capacity - sum_of_rates, 0)
    return largest_rate + spare_capacity


def correct_threshold(true_flow_rates: List[int], link_capacity: int) -> int:
    """ If the link is busy, return the max-min fairness threshold.
        Otherwise, return the speculative threshold.
    """
    sum_of_rates = sum(true_flow_rates)
    if sum_of_rates < link_capacity:
        return speculative_threshold(true_flow_rates, link_capacity)

    def accepting_rate_if_threshold_was(candidate_threshold: int) -> int:
        return sum(min(flow_rate, candidate_threshold) for flow_rate in true_flow_rates)

    return binary_search_for_input(desired_output=link_capacity,
                                   input_lo=0,
                                   input_hi=link_capacity,
                                   func=accepting_rate_if_threshold_was)


class CapacityEstimator(ABC):
    @abstractmethod
    def __init__(self, slice_weights: List[float], physical_capacity: int):
        pass

    @abstractmethod
    def process_packet(self, pkt_size: int, slice_id: int, timestamp: int):
        return NotImplemented

    @abstractmethod
    def end_epoch(self) -> None:
        return None

    @abstractmethod
    def capacity_for(self, slice_id: int) -> int:
        return NotImplemented

    @abstractmethod
    def capacities(self) -> List[int]:
        return NotImplemented

    @abstractmethod
    def get_scaled_capacity(self) -> int:
        return NotImplemented


class CapacityFixed(CapacityEstimator):
    slice_weights: List[float]
    physical_capacity: int

    def __init__(self, slice_weights: List[float], physical_capacity: int):
        self.slice_weights = slice_weights.copy()
        self.physical_capacity = physical_capacity

    def process_packet(self, pkt_size: int, slice_id: int, timestamp: int):
        return None

    def end_epoch(self) -> None:
        return None

    def capacity_for(self, slice_id: int) -> int:
        return int(self.physical_capacity * self.slice_weights[slice_id])

    def capacities(self) -> List[int]:
        return [self.capacity_for(slice_id) for slice_id in range(len(self.slice_weights))]

    def get_scaled_capacity(self) -> int:
        return self.physical_capacity


class CapacityHistograms(CapacityEstimator):
    num_slices: int = 0
    slice_weights: List[float]  # per-slice share fractions of the physical base station link (should add up to 1)
    physical_capacity: int  # number of bytes the physical base station link can send in one epoch
    scaled_capacity: int  # capacity scaled up in response to at least one slice not claiming its fair share
    default_to_speculative: bool  # default to the speculative horizontal slice if if the link is not oversubscribed

    slice_demand_lpfs: List[LpfSingleton]  # LPFs that track the demand rate of each slice

    def __init__(self, slice_weights: List[float], physical_capacity: int, default_to_speculative: bool = True):
        assert (sum(slice_weights) == 1.0)
        for weight in slice_weights:
            assert (0.0 < weight <= 1.0)
        self.slice_weights = slice_weights.copy()
        self.num_slices = len(self.slice_weights)
        self.slice_demand_lpfs = [LpfSingleton(time_constant=LPF_DECAY, scale_down_factor=LPF_SCALE)
                                  for _ in range(self.num_slices)]

        self.physical_capacity = physical_capacity
        self.scaled_capacity = physical_capacity  # initially unscaled
        self.default_to_speculative = default_to_speculative

    def process_packet(self, pkt_size: int, slice_id: int, timestamp: int):
        self.slice_demand_lpfs[slice_id].update(timestamp=timestamp, value=pkt_size)

    def end_epoch(self) -> None:
        """
        End-of-epoch computation of new per-slice capacities
        :return: None
        """
        # if the lightest slice is the only one in use, scale will be this
        max_scale = int(self.physical_capacity / min(self.slice_weights)) + 1
        # if all slice loads are at or below capacity,

        slice_demands = [lpf.get() for lpf in self.slice_demand_lpfs]

        def bytes_sent_if_scaled_capacity_was(scaled_capacity: int) -> int:
            return sum(min(slice_demands[i], int(self.slice_weights[i] * scaled_capacity))
                       for i in range(self.num_slices))

        if sum(slice_demands) < self.physical_capacity:
            # If the base station is underutilized, the scaled capacity will jump to the maximum.
            # However, if default_to_speculative is true, the scaled capacity should instead go to the
            # speculative horizontal cut. The speculative horizontal cut is the lowest capacity that would
            # still allow the current busiest slice to grow to fill the link
            if self.default_to_speculative:
                # how much unused capacity is there in the link?
                spare_capacity = max(0, self.physical_capacity - sum(slice_demands))
                busiest_slice_id = argmax(slice_demands)
                # if the busiest slice were to grow to fill the link, what would its demand be?
                busiest_slices_potential_demand = slice_demands[busiest_slice_id] + spare_capacity
                # what would the scaled capacity be if the busiest slice filled the link?
                self.scaled_capacity = int(busiest_slices_potential_demand / self.slice_weights[busiest_slice_id])
            else:
                self.scaled_capacity = max_scale
        else:
            self.scaled_capacity = binary_search_for_input(desired_output=self.physical_capacity,
                                                           input_lo=0,
                                                           input_hi=max_scale,
                                                           func=bytes_sent_if_scaled_capacity_was)

    def capacity_for(self, slice_id: int) -> int:
        """
        The capacity available for the given slice in the current epoch
        :param slice_id: ID of the slice
        :return: current capacity of the slice in bytes
        """
        return int(self.scaled_capacity * self.slice_weights[slice_id])

    def capacities(self) -> List[int]:
        return [int(self.scaled_capacity * weight) for weight in self.slice_weights]

    def get_scaled_capacity(self) -> int:
        """
        The total vtrunk capacity, scaled up to permit busy flows to grow
        :return:
        """
        return self.scaled_capacity


class ThresholdEstimator(ABC):
    @abstractmethod
    def process_packet(self, packet_size: int, flow_rate: int, timestamp: int) -> None:
        """
        :param packet_size: Size of the current packet
        :param flow_rate: Estimate of the current packet's flow's rate
        :param timestamp: Timestamp of packet's arrival
        """
        return None

    @abstractmethod
    def set_threshold(self, threshold: int) -> None:
        return None

    @abstractmethod
    def get_current_threshold(self) -> int:
        return NotImplemented

    @abstractmethod
    def end_epoch(self, capacity: int) -> int:
        """
        :param capacity: the capacity of the current epoch
        :return: the new threshold
        """
        return NotImplemented

    @abstractmethod
    def clear_lpfs(self) -> None:
        return None


def create_power_two_jump_candidates(threshold: int) -> List[int]:
    """
    Given a current threshold, return three threshold candidates.
    The middle candidate is equal to the current threshold.
    The low and high candidates are equal to the current threshold plus or minus the power of two closest to half
    the current threshold.
    :param threshold:
    :return:
    """
    assert (threshold > 0)
    increase_distance = 1 << (round(math.log(threshold, 2.0)) - 2)  # threshold can increase to ~1.25x
    decrease_distance = 1 << (round(math.log(threshold, 2.0)) - 1)  # threshold can decrease to ~0.5x
    return [max(threshold - decrease_distance, 1), threshold, threshold + increase_distance]


def create_relative_candidates(ratios: List[float], threshold: int):
    return [int(threshold * ratio) for ratio in ratios]


create_three_relative_candidates = partial(create_relative_candidates, [0.5, 1.0, 2.0])

create_five_relative_candidates = partial(create_relative_candidates, [0.5, 0.75, 1.0, 1.5, 2.0])


class ThresholdHistograms(ThresholdEstimator):
    candidates: List[int]
    candidate_lpfs: List[LpfSingleton]
    num_candidates: int = 0
    candidate_generator: Callable[[int], List[int]]

    curr_threshold: int = 0
    minimum_threshold: int = 8
    maximum_threshold: int = (1 << 30)

    total_slice_demand_lpf: LpfSingleton
    max_flow_rate_this_epoch: int = 0
    default_to_speculative: bool

    def __init__(self, candidate_generator: Optional[Callable[[int], List[int]]] = None,
                 default_to_speculative: bool = True):
        if candidate_generator is None:
            self.candidate_generator = create_five_relative_candidates
        else:
            self.candidate_generator = candidate_generator
        self.num_candidates = len(self.candidate_generator(1024))  # throw a dummy value in to see what comes out
        self.curr_threshold = self.maximum_threshold
        self.default_to_speculative = default_to_speculative
        self.total_slice_demand_lpf = LpfSingleton(time_constant=LPF_DECAY, scale_down_factor=LPF_SCALE)
        self.candidate_lpfs = [LpfSingleton(time_constant=LPF_DECAY, scale_down_factor=LPF_SCALE)
                               for _ in range(self.num_candidates)]
        self.init_per_epoch_structs()

    def set_threshold_bounds(self, minimum: int, maximum: int):
        self.minimum_threshold = minimum
        self.maximum_threshold = maximum

    def init_per_epoch_structs(self) -> None:
        self.candidates = [self.bound_threshold(candidate)
                           for candidate in self.candidate_generator(self.curr_threshold)]
        self.max_flow_rate_this_epoch = 0

    def process_packet(self, packet_size: int, flow_rate: int, timestamp: int) -> None:
        self.total_slice_demand_lpf.update(timestamp, packet_size)
        self.max_flow_rate_this_epoch = max(flow_rate, self.max_flow_rate_this_epoch)
        for i, candidate in enumerate(self.candidates):
            self.candidate_lpfs[i].update(timestamp, bytes_accepted(flow_rate, candidate, packet_size))

    def get_speculative_threshold(self, capacity: int) -> int:
        # largest flow size plus spare capacity
        return self.max_flow_rate_this_epoch + max(0, capacity - self.total_slice_demand_lpf.get())

    def set_threshold(self, threshold: int) -> None:
        self.curr_threshold = self.bound_threshold(threshold)
        self.init_per_epoch_structs()

    def bound_threshold(self, threshold: int) -> int:
        """
        Clip the provided threshold to the defined boundaries.
        :param threshold: threshold to be clipped
        :return: clipped threshold
        """
        return min(self.maximum_threshold, max(threshold, self.minimum_threshold))

    def choose_winning_threshold(self, threshold: int, capacity: int) -> int:
        self.curr_threshold = threshold
        if self.default_to_speculative:
            self.curr_threshold = min(self.curr_threshold, self.get_speculative_threshold(capacity))
        self.curr_threshold = self.bound_threshold(self.curr_threshold)
        self.init_per_epoch_structs()
        return self.curr_threshold

    def get_current_threshold(self) -> int:
        return self.curr_threshold

    def end_epoch(self, capacity: int) -> int:
        winning_threshold: int
        for i in range(self.num_candidates):
            if self.candidate_lpfs[i].get() > capacity:
                winning_threshold = self.candidates[max(0, i - 1)]
                break
        else:
            winning_threshold = self.candidates[-1]  # if all candidates are valid, return the largest
        return self.choose_winning_threshold(winning_threshold, capacity)

    def clear_lpfs(self) -> None:
        for lpf in self.candidate_lpfs:
            lpf.clear()


class ThresholdNewtonMethodBase(ThresholdHistograms):
    threshold_interpolator: ThresholdInterpolator

    def __init__(self, threshold_interpolator: ThresholdInterpolator,
                 candidate_generator: Callable[[int], List[int]], default_to_speculative: bool = True):
        self.threshold_interpolator = threshold_interpolator
        super().__init__(candidate_generator=candidate_generator,
                         default_to_speculative=default_to_speculative)

    def end_epoch(self, capacity: int) -> int:
        winning_threshold = -1
        lo_index = -1
        hi_index = -1
        candidate_rates = [lpf.get() for lpf in self.candidate_lpfs]
        if capacity < candidate_rates[1]:
            # middle threshold candidate's count exceeds capacity
            if capacity <= candidate_rates[0]:
                # lower than the lowest threshold candidate
                winning_threshold = self.candidates[0]
            else:
                # capacity is met between low and middle threshold candidates
                lo_index = 0
                hi_index = 1
        elif capacity > candidate_rates[1]:
            # middle threshold's count is below capacity
            if capacity >= candidate_rates[2]:
                # higher than the highest threshold
                winning_threshold = self.candidates[2]
            else:
                # capacity is met between middle and high threshold candidates
                lo_index = 1
                hi_index = 2
        else:
            # middle threshold exactly meets capacity
            winning_threshold = self.candidates[1]

        if winning_threshold == -1:
            # threshold is somewhere between the low and high candidates

            c1, c2 = candidate_rates[lo_index], candidate_rates[hi_index]
            t1, t2 = self.candidates[lo_index], self.candidates[hi_index]

            winning_threshold = self.threshold_interpolator.interpolate(t1, t2, c1, c2, capacity)
        return self.choose_winning_threshold(winning_threshold, capacity)


class ThresholdNewtonMethodTofino(ThresholdNewtonMethodBase):
    def __init__(self, default_to_speculative=True):
        interpolator = TofinoThresholdInterpolator()
        super().__init__(threshold_interpolator=interpolator, candidate_generator=create_power_two_jump_candidates,
                         default_to_speculative=default_to_speculative)


class ThresholdNewtonMethodAccurate(ThresholdNewtonMethodBase):
    def __init__(self, default_to_speculative=True):
        interpolator = ExactThresholdInterpolator()
        super().__init__(threshold_interpolator=interpolator, candidate_generator=create_three_relative_candidates,
                         default_to_speculative=default_to_speculative)


def test_binary_search():
    def clipped_doubler(x: int) -> int:
        return min(x * 2, 35)

    for lo, hi, desired in [(0, 15, 30), (0, 50, 35), (0, 50, 15), (0, 50, 0), (0, 28, 14)]:
        correct = min((desired + 1) // 2, 18)
        found = binary_search_for_input(desired_output=desired, input_lo=lo, input_hi=hi, func=clipped_doubler)
        if found != correct:
            print("Binary search failed when seeking output %d between inputs %d and %d" % (desired, lo, hi))
            print("Found %d, expected %d" % (found, correct))
        else:
            print("A binary search test passed")


def test_capacity_estimator():
    capacity = 5000
    slice_weights = [0.5, 0.25, 0.125, 0.125]
    ch = CapacityHistograms(slice_weights=slice_weights, physical_capacity=capacity)

    # Only one slice in use, and overloaded
    ch.process_packet(pkt_size=10000, slice_id=3, timestamp=0)
    ch.end_epoch()
    print("Capacity scaling test 1 ", end="")
    if ch.scaled_capacity != int(capacity / slice_weights[3]):
        print("failed.")
    else:
        print("passed.")

    # All slices overloaded
    ch = CapacityHistograms(slice_weights=slice_weights, physical_capacity=capacity)
    for i in range(len(slice_weights)):
        ch.process_packet(pkt_size=10000, slice_id=i, timestamp=0)
    ch.end_epoch()
    print("Capacity scaling test 2 ", end="")
    if ch.scaled_capacity != capacity:
        print("failed.")
    else:
        print("passed.")

    # All slices at perfect utilization
    ch = CapacityHistograms(slice_weights=slice_weights, physical_capacity=capacity)
    for i in range(len(slice_weights)):
        ch.process_packet(pkt_size=int(capacity * slice_weights[i]), slice_id=i, timestamp=0)
    ch.end_epoch()
    print("Capacity scaling test 3 ", end="")
    if ch.scaled_capacity != capacity:
        print("failed. Capacity {} instead of {}".format(ch.scaled_capacity, capacity))
    else:
        print("passed.")

    # Three of four slices underloaded, one slice overloaded
    ch = CapacityHistograms(slice_weights=slice_weights, physical_capacity=capacity)
    for i in range(len(slice_weights[:-1])):
        ch.process_packet(pkt_size=50, slice_id=i, timestamp=0)
    ch.process_packet(pkt_size=10000, slice_id=3, timestamp=0)
    ch.end_epoch()
    print("Capacity scaling test 4 ", end="")
    # capacity unused by the 3 underloaded slices determines the scaling factor
    if ch.scaled_capacity != int((capacity - 50 * 3) / slice_weights[3]):
        print("failed.")
    else:
        print("passed.")


def threshold_estimation_test(th: ThresholdEstimator, pkts: List[Tuple[int, int]],
                              starting_threshold: int, expected_ending_threshold: int,
                              link_capacity: int, test_name: str = "test",
                              permitted_absolute_error: int = 0):
    """
    Check that the threshold estimator chooses the expected next-window threshold given some set of packets
    :param th: a threshold estimator
    :param pkts: the packets to feed to the estimator
    :param starting_threshold: the initial threshold to be applied to flows
    :param expected_ending_threshold: the new threshold for the next window that the estimator should choose
    :param link_capacity: how many bytes per window are permitted across all flows
    :param test_name: name of this test, for printing
    :param permitted_absolute_error: how much the new threshold can deviate from the expectation
    :return: None
    """
    if starting_threshold != -1:
        th.set_threshold(starting_threshold)
    else:
        starting_threshold = th.get_current_threshold()
    for i, (pkt_size, flow_size) in enumerate(pkts):
        th.process_packet(packet_size=pkt_size, flow_rate=flow_size, timestamp=0)
    th.end_epoch(capacity=link_capacity)
    end_thresh = th.get_current_threshold()
    end_lo = expected_ending_threshold - permitted_absolute_error
    end_hi = expected_ending_threshold + permitted_absolute_error
    if end_lo <= end_thresh <= end_hi:
        print(type(th).__name__, "passed %s. Threshold went from %d to %d"
              % (test_name, starting_threshold, end_thresh))
    else:
        print(type(th).__name__, "FAILED %s: Threshold went from %d to %d instead of %d+-%d"
              % (test_name, starting_threshold, end_thresh, expected_ending_threshold, permitted_absolute_error))
    th.clear_lpfs()


def test_threshold_estimator():
    for ThresholdClass in [ThresholdHistograms, ThresholdNewtonMethodAccurate]:
        th = ThresholdClass(default_to_speculative=False)

        # Even distribution, surplus capacity, threshold far too low
        # Threshold should double
        threshold_estimation_test(th,
                                  pkts=[(50, 0) for _ in range(10)],
                                  starting_threshold=50,
                                  expected_ending_threshold=100,
                                  link_capacity=10000,
                                  test_name="Test1")

        # Even distribution, insufficient capacity, threshold far too high
        # Threshold should halve
        threshold_estimation_test(th,
                                  pkts=[(50, 0) for _ in range(10)],
                                  starting_threshold=50,
                                  expected_ending_threshold=25,
                                  link_capacity=50,
                                  test_name="Test2")

        # Even distribution, insufficient capacity, threshold slightly too high
        # Threshold should decrease by 25%
        threshold_estimation_test(th,
                                  pkts=[(100, 100) for _ in range(10)],
                                  starting_threshold=64,
                                  expected_ending_threshold=48,
                                  link_capacity=480,
                                  test_name="Test3")

        # Even distribution, surplus capacity, threshold slightly too low
        # Threshold should increase by 50%
        threshold_estimation_test(th,
                                  pkts=[(128, 128) for _ in range(10)],
                                  starting_threshold=64,
                                  expected_ending_threshold=96,
                                  link_capacity=960,
                                  test_name="Test4")
        # TODO: more tests


def test_newton_estimator():
    for Class in [ThresholdNewtonMethodAccurate, ThresholdNewtonMethodTofino]:
        th = Class()

        # Skewed distribution, insufficient capacity, threshold slightly too high
        # Check that the threshold converges to the correct value
        pkts = []
        bytes_sent = 0
        flow_sizes = []
        for i in range(0, 41, 2):
            # flow sizes are [10, 12, 14, 16, ..., 48, 50]
            flow_size = 10 + i + 1
            for j in range(flow_size):
                pkts.append((1, j))
                bytes_sent += 1
            flow_sizes.append(flow_size)
        link_capacity = 480
        expected_threshold = correct_threshold(flow_sizes, link_capacity)
        threshold_estimation_test(th,
                                  pkts=pkts,
                                  starting_threshold=40,
                                  expected_ending_threshold=expected_threshold,
                                  link_capacity=link_capacity,
                                  test_name="Convergence Test1",
                                  permitted_absolute_error=2)

        threshold_estimation_test(th,
                                  pkts=pkts,
                                  starting_threshold=-1,  # reuse ending threshold from last test
                                  expected_ending_threshold=expected_threshold,
                                  link_capacity=link_capacity,
                                  test_name="Convergence Test2",
                                  permitted_absolute_error=1)

        threshold_estimation_test(th,
                                  pkts=pkts,
                                  starting_threshold=-1,  # reuse ending threshold from last test
                                  expected_ending_threshold=expected_threshold,
                                  link_capacity=link_capacity,
                                  test_name="Convergence Test3",
                                  permitted_absolute_error=1)


if __name__ == "__main__":
    test_binary_search()
    test_capacity_estimator()
    test_threshold_estimator()
    test_newton_estimator()
