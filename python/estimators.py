from abc import ABC, abstractmethod
from typing import List, Optional, Callable

import math


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
    assert(input_hi > input_lo)
    assert(func(input_hi) >= desired_output >= func(input_lo))
    input_arg = int((input_lo + input_hi) / 2)
    output = func(input_arg)
    while True:
        #print("Curr: %d, Lo: %d, Hi: %d, Desired: %d, Found: %d"
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
            #print("Pointers converged. Lo: %d, Hi: %d" % (input_lo, input_hi))
            return input_hi
        if new_input_arg == input_arg:
            raise Exception("BUG: binary search got stuck. Lo: %d, Hi: %d, curr: %d, output: %d, desired: %d"
                            % (input_lo, input_hi, input_arg, output, desired_output))
        input_arg = new_input_arg
        output = func(input_arg)


class CapacityHistograms:
    num_slices: int = 0
    slice_weights: List[float]  # per-slice share fractions of the physical base station link (should add up to 1)
    slice_demands: List[int]    # how many bytes each slice attempted to send this epoch, including dropped packets
    physical_capacity: int      # number of bytes the physical base station link can send in one epoch
    scaled_capacity: int        # capacity scaled up in response to at least one slice not claiming its fair share

    def __init__(self, slice_weights: List[float], physical_capacity: int):
        assert(sum(slice_weights) == 1.0)
        for weight in slice_weights:
            assert(0.0 < weight <= 1.0)
        self.slice_weights = slice_weights.copy()
        self.num_slices = len(self.slice_weights)
        self.slice_demands = [0] * self.num_slices
        self.physical_capacity = physical_capacity

    def process_packet(self, pkt_size: int, slice_id: int):
        self.slice_demands[slice_id] += pkt_size

    def bytes_sent_if_scaled_capacity_was(self, scaled_capacity: int) -> int:
        """
        How many bytes would have been sent if we scaled the link capacity (i.e. scaled every slice's share)
        :param scaled_capacity: scaled link capacity. minimum value is `self.physical_capacity`
        :return: How many bytes would have been sent overall
        """
        return sum(min(self.slice_demands[i], int(self.slice_weights[i] * scaled_capacity))
                   for i in range(self.num_slices))

    def end_epoch(self) -> None:
        """
        End-of-epoch computation of new per-slice capacities
        :return: None
        """
        # if the lightest slice is the only one in use, scale will be this
        max_scale = int(self.physical_capacity / min(self.slice_weights)) + 1
        # if all slice loads are at or below capacity,

        self.scaled_capacity = binary_search_for_input(self.physical_capacity, 0, max_scale,
                                                       self.bytes_sent_if_scaled_capacity_was)
        self.slice_demands = [0] * self.num_slices

    def capacity_for(self, slice_id: int) -> int:
        """
        The capacity available for the given slice in the current epoch
        :param slice_id: ID of the slice
        :return: current capacity of the slice in bytes
        """
        return int(self.scaled_capacity * self.slice_weights[slice_id])

    def capacities(self) -> List[int]:
        return [int(self.scaled_capacity * weight) for weight in self.slice_weights]

    def scaled_capacity(self) -> int:
        return self.scaled_capacity


class ThresholdEstimator(ABC):
    @abstractmethod
    def process_packet(self, packet_size: int, flow_size: int) -> bool:
        """
        :param packet_size: Size of the current packet
        :param flow_size: Bytes sent by the current packet's flow, excluding the current packet
        :return: true if the packet would be sent to the low-priority queue, false otherwise
        """
        return NotImplemented

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


class ThresholdHistograms(ThresholdEstimator):
    candidate_ratios: List[float]
    candidates: List[int]
    curr_threshold: int = 0
    candidate_counters: List[int]
    num_candidates: int = 0

    def __init__(self, candidate_ratios: Optional[List[float]] = None):
        if candidate_ratios is None:
            self.candidate_ratios = [0.5, 0.75, 1, 1.5, 2]
        else:
            self.candidate_ratios = candidate_ratios.copy()
        self.candidate_ratios.sort()
        self.num_candidates = len(self.candidate_ratios)
        self.candidates = [0] * self.num_candidates
        self.candidate_counters = [0] * self.num_candidates

    def process_packet(self, packet_size: int, flow_size: int) -> bool:
        for i in range(self.num_candidates):
            if flow_size < self.candidates[i]:
                self.candidate_counters[i] += packet_size
            else:
                break
        return flow_size > self.curr_threshold

    def set_threshold(self, threshold: int) -> None:
        self.curr_threshold = threshold
        self.candidates = [int(self.curr_threshold * ratio) for ratio in self.candidate_ratios]
        self.candidate_counters = [0] * self.num_candidates

    def get_current_threshold(self) -> int:
        return self.curr_threshold

    def end_epoch(self, capacity: int) -> int:
        winning_threshold = 0
        for i in range(self.num_candidates):
            if self.candidate_counters[i] > capacity:
                winning_threshold = self.candidates[max(0, i-1)]
                break
        else:
            winning_threshold = self.candidates[-1]  # if all candidates are valid, return the largest
        self.set_threshold(winning_threshold)
        return winning_threshold


class ThresholdNewtonMethod(ThresholdHistograms):

    def __init__(self, max_ratio = 2.0):
        super().__init__(candidate_ratios=[1.0/max_ratio, 1.0, max_ratio])

    def end_epoch(self, capacity: int) -> int:
        winning_threshold = -1
        lo_index = -1
        hi_index = -1
        if capacity < self.candidate_counters[1]:
            # middle threshold candidate's count exceeds capacity
            if capacity <= self.candidate_counters[0]:
                # lower than the lowest threshold candidate
                winning_threshold = self.candidates[0]
            else:
                # capacity is met between low and middle threshold candidates
                lo_index = 0
                hi_index = 1
        elif capacity > self.candidate_counters[1]:
            # middle threshold's count is below capacity
            if capacity >= self.candidate_counters[2]:
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

            c1, c2 = self.candidate_counters[lo_index], self.candidate_counters[hi_index]
            t1, t2 = self.candidates[lo_index], self.candidates[hi_index]

            x = (capacity - c2) / (c1 - c2)

            winning_threshold = int((x * t1) + ((1 - x) * t2))
        self.set_threshold(winning_threshold)
        return winning_threshold


def test_binary_search():
    def clipped_doubler(x: int) -> int:
        return min(x * 2, 35)
    for lo, hi, desired in [(0, 15, 30), (0, 50, 35), (0, 50, 15), (0, 50, 0), (0, 28, 14)]:
        correct = min((desired+1) // 2, 18)
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
    ch.process_packet(pkt_size=10000, slice_id=3)
    ch.end_epoch()
    print("Capacity scaling test 1 ", end="")
    if ch.scaled_capacity != int(capacity / slice_weights[3]):
        print("failed.")
    else:
        print("passed.")

    # All slices overloaded
    for i in range(len(slice_weights)):
        ch.process_packet(pkt_size=10000, slice_id=i)
    ch.end_epoch()
    print("Capacity scaling test 2 ", end="")
    if ch.scaled_capacity != capacity:
        print("failed.")
    else:
        print("passed.")

    # All slices at perfect utilization
    for i in range(len(slice_weights)):
        ch.process_packet(pkt_size=int(capacity * slice_weights[i]), slice_id=i)
    ch.end_epoch()
    print("Capacity scaling test 3 ", end="")
    if ch.scaled_capacity != capacity:
        print("failed.")
    else:
        print("passed.")

    # Three of four slices underloaded, one slice overloaded
    for i in range(len(slice_weights[:-1])):
        ch.process_packet(pkt_size=50, slice_id=i)
    ch.process_packet(pkt_size=10000, slice_id=3)
    ch.end_epoch()
    print("Capacity scaling test 4 ", end="")
    # capacity unused by the 3 underloaded slices determines the scaling factor
    if ch.scaled_capacity != int((capacity - 50 * 3) / slice_weights[3]):
        print("failed.")
    else:
        print("passed.")


def test_threshold_estimator():
    th = ThresholdHistograms()
    th.set_threshold(50)
    # even distribution, surplus capacity, threshold doubles
    for _ in range(10):
        th.process_packet(packet_size=50, flow_size=0)
    th.end_epoch(capacity=10000)
    if th.get_current_threshold() != 100:
        print("Threshold did not double as expected")
    else:
        print("Threshold doubled.")
    # even distribution, insufficient capacity, threshold halves
    for _ in range(10):
        th.process_packet(packet_size=50, flow_size=0)
    th.end_epoch(capacity=50)
    if th.get_current_threshold() != 50:
        print("Threshold:", th.get_current_threshold())
        print("Threshold did not halve")
    else:
        print("Threshold halved.")
    # TODO: more tests


if __name__ == "__main__":
    test_binary_search()
    test_capacity_estimator()
    test_threshold_estimator()
