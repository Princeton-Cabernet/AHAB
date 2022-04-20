#!/usr/bin/python3
import random
from collections import defaultdict
from dataclasses import dataclass
from statistics import mean
from typing import List, Tuple, Dict, Set, Type

import numpy as np

from common import FlowId, SEED, bytes_rejected
from estimators import ThresholdEstimator, ThresholdNewtonMethodTofino, CapacityHistograms, correct_threshold, \
    CapacityEstimator, CapacityFixed
from rate_estimators import RateEstimator

random.seed(SEED)  # for reproducible tests


@dataclass
class SliceEpochRecord:
    flow_ids: List[FlowId]
    flow_sizes: List[int]
    flow_drops: List[int]
    threshold_chosen: int
    capacity_chosen: int
    capacity_ideal: int
    threshold_ideal: int = -1
    flow_drops_ideal: List[int] = None

    def __post_init__(self):
        self.threshold_ideal = correct_threshold(self.flow_sizes,
                                                 self.capacity_ideal)

        self.flow_drops_ideal = [max(flow_size - self.threshold_ideal, 0) for flow_size in self.flow_sizes]

    def drop_rates_per_relative_flow_size(self) -> Dict[float, float]:
        result = {}
        for flow_index in range(len(self.flow_sizes)):
            relative_flow_size = self.flow_sizes[flow_index] / self.threshold_ideal
            drop_rate = self.flow_drops[flow_index] / self.flow_sizes[flow_index]
            result[relative_flow_size] = drop_rate
        return result

    def drop_rates(self) -> List[float]:
        return [drops / flow_size for (drops, flow_size) in zip(self.flow_drops, self.flow_sizes)]

    def drop_rates_ideal(self) -> List[float]:
        return [drops / flow_size for (drops, flow_size) in zip(self.flow_drops_ideal, self.flow_sizes)]

    def drop_rate_diffs(self) -> List[float]:
        return [(drops - drops_ideal) / flow_size
                for (drops, drops_ideal, flow_size) in zip(self.flow_drops, self.flow_drops_ideal, self.flow_sizes)]

    def fairness_mean(self) -> float:
        return mean(self.drop_rate_diffs())

    def fairness_l1(self) -> float:
        return np.linalg.norm(self.drop_rate_diffs(), ord=1)

    def fairness_l2(self) -> float:
        return np.linalg.norm(self.drop_rate_diffs(), ord=2)

    def fairness_linf(self) -> float:
        return max(abs(diff) for diff in self.drop_rate_diffs())


class QosHistory:
    # Outer list indexed by epochID, inner lists indexed by sliceID
    history: List[List[SliceEpochRecord]]
    slice_weights: List[float]
    num_slices: int
    num_epochs: int

    def __init__(self, slice_weights: List[float]):
        self.slice_weights = slice_weights.copy()
        self.num_slices = len(slice_weights)
        self.history = list()
        self.num_epochs = 0

    def trim_first_epochs(self, trim_count):
        self.history = self.history[trim_count:]
        self.num_epochs = len(self.history)

    def add_epoch(self, epoch_record: List[SliceEpochRecord]):
        self.history.append(epoch_record)
        self.num_epochs += 1

    def records_for(self, slice_id: int) -> List[SliceEpochRecord]:
        return [record[slice_id] for record in self.history]

    def fairness_l1_history_for(self, slice_id: int) -> List[float]:
        return [record[slice_id].fairness_l1() for record in self.history]

    def fairness_l2_history_for(self, slice_id: int) -> List[float]:
        return [record[slice_id].fairness_l2() for record in self.history]

    def fairness_linf_history_for(self, slice_id: int) -> List[float]:
        return [record[slice_id].fairness_linf() for record in self.history]

    def fairness_mean_history_for(self, slice_id: int) -> List[float]:
        return [record[slice_id].fairness_mean() for record in self.history]

    def threshold_error_for(self, slice_id: int) -> List[float]:
        return [(record[slice_id].threshold_chosen - record[slice_id].threshold_ideal)
                / record[slice_id].threshold_ideal
                for record in self.history]


class ApproxQos:
    num_slices: int

    slice_weights: List[float]
    scale_factors: List[int]  # one factor per slice, used to scale packets up/down to appear heavier/lighter

    flow_rate_estimator: RateEstimator  # returns a point estimate of each flow's current rate
    threshold_estimators: List[ThresholdEstimator]  # one estimator per slice. Determines intra-slice fair rate
    capacity_estimator: CapacityEstimator  # determines each slice's capacity, according to inter-slice max-min fairness

    def __init__(self, slice_weights: List[float],
                 vtrunk_capacity: int,
                 rate_estimator: RateEstimator,
                 threshold_estimator_class: Type[ThresholdEstimator] = ThresholdNewtonMethodTofino,
                 fixed_capacities: bool = False):
        self.num_slices = len(slice_weights)
        self.slice_weights = slice_weights.copy()

        self.flow_rate_estimator = rate_estimator

        self.threshold_estimators = [threshold_estimator_class() for _ in range(self.num_slices)]
        if fixed_capacities:
            self.capacity_estimator = CapacityFixed(self.slice_weights, vtrunk_capacity)
        else:
            self.capacity_estimator = CapacityHistograms(self.slice_weights, vtrunk_capacity)
        for slice_id, estimator in enumerate(self.threshold_estimators):
            # Choose an arbitrary initial threshold for each slice
            estimator.set_threshold(int(self.capacity_estimator.capacity_for(slice_id) / 6))

        heaviest_weight = max(self.slice_weights)
        # there is no rounding error here if every weight is a power of 2, as will be the case in tofino
        self.scale_factors = [int(heaviest_weight / weight) for weight in self.slice_weights]
        self.__post_init__()

    def __post_init__(self):
        pass

    def process_packet(self, packet_timestamp: int, packet_size: int, slice_id: int, packet_key: FlowId) -> int:
        # Scale the packet's size up before putting into the flow rate sketch
        scale_factor = self.scale_factors[slice_id]
        scaled_size = packet_size * scale_factor
        # Put the scaled-up packet size into the flow rate sketch to retrieve a flow rate estimate
        estimated_flow_size = self.flow_rate_estimator.update(key=packet_key,
                                                              timestamp=packet_timestamp,
                                                              value=scaled_size)
        # Scale the sketch output down to get the true estimated flow rate
        estimated_flow_size = int(estimated_flow_size / scale_factor)

        # Grab the current threshold for the packet's slice
        threshold = self.threshold_estimators[slice_id].get_current_threshold()
        # to reduce experiment variance, just grab expected drop outcomes
        expected_dropped_bytes = bytes_rejected(estimated_flow_size, threshold, packet_size)

        # Pass the packet to the threshold and capacity estimator structures
        self.threshold_estimators[slice_id].process_packet(packet_size, estimated_flow_size, packet_timestamp)
        self.capacity_estimator.process_packet(slice_id=slice_id, pkt_size=packet_size, timestamp=packet_timestamp)

        return expected_dropped_bytes

    def end_epoch(self) -> None:
        # Compute new per-slice capacity
        self.capacity_estimator.end_epoch()
        # Compute each slice's new per-flow threshold
        for slice_id, estimator in enumerate(self.threshold_estimators):
            estimator.end_epoch(self.capacity_estimator.capacity_for(slice_id))


class ApproxQosWithSavedStats(ApproxQos):
    relative_flow_size_drop_rate_pairs: List[Tuple[float, float]]
    dropped_bytes_per_flow_this_epoch: Dict[FlowId, int]
    received_bytes_per_flow_this_epoch: Dict[FlowId, int]
    slice_to_flows: Dict[int, Set[FlowId]]

    history: QosHistory

    def __post_init__(self):
        self.history = QosHistory(slice_weights=self.slice_weights)
        self.relative_flow_size_drop_rate_pairs = []
        self.clear_per_epoch_structs()

    def clear_per_epoch_structs(self) -> None:
        self.dropped_bytes_per_flow_this_epoch = defaultdict(int)
        self.received_bytes_per_flow_this_epoch = defaultdict(int)
        self.slice_to_flows = defaultdict(set)

    def process_packet(self, packet_timestamp: int, packet_size: int, slice_id: int, packet_key: FlowId) -> int:
        expected_dropped_bytes = super().process_packet(packet_timestamp,
                                                        packet_size,
                                                        slice_id,
                                                        packet_key)

        self.received_bytes_per_flow_this_epoch[packet_key] += packet_size
        self.dropped_bytes_per_flow_this_epoch[packet_key] += expected_dropped_bytes
        self.slice_to_flows[slice_id].add(packet_key)

        return expected_dropped_bytes

    def end_epoch(self) -> None:
        # Save the thresholds and capacities from this epoch
        thresholds_chosen = [estimator.get_current_threshold() for estimator in self.threshold_estimators]
        capacities_chosen = self.capacity_estimator.capacities()

        # update capacities and thresholds
        super().end_epoch()

        epoch_record = []
        for slice_id in range(self.num_slices):
            capacity_in_hindsight = self.capacity_estimator.capacity_for(slice_id)
            flow_ids = list(self.slice_to_flows[slice_id])

            epoch_record.append(SliceEpochRecord(flow_ids=flow_ids,
                                                 flow_sizes=[self.received_bytes_per_flow_this_epoch[flow_id]
                                                             for flow_id in flow_ids],
                                                 flow_drops=[self.dropped_bytes_per_flow_this_epoch[flow_id]
                                                             for flow_id in flow_ids],
                                                 threshold_chosen=thresholds_chosen[slice_id],
                                                 capacity_chosen=capacities_chosen[slice_id],
                                                 capacity_ideal=capacity_in_hindsight))
        self.history.add_epoch(epoch_record)
        self.clear_per_epoch_structs()

    def get_history(self) -> QosHistory:
        return self.history


class PerfectQos:
    num_slices: int
    slice_weights: List[float]
    total_capacity: int

    bytes_per_flow: Dict[FlowId, int]
    slice_to_flows: Dict[int, Set[FlowId]]

    capacity_estimator: CapacityHistograms

    dropped_bytes_per_flow: Dict[FlowId, int]

    def __init__(self, slice_weights: List[float], base_station_capacity: int):
        self.total_capacity = base_station_capacity
        self.slice_weights = slice_weights
        self.clear_per_epoch_structs()
        self.capacity_estimator = CapacityHistograms(self.slice_weights, base_station_capacity)

    def clear_per_epoch_structs(self):
        self.bytes_per_flow = defaultdict(int)
        self.slice_to_flows = defaultdict(set)

    def process_packet(self, packet_key: FlowId, packet_size: int, slice_id: int, timestamp: int):
        self.bytes_per_flow[packet_key] += packet_size
        self.slice_to_flows[slice_id].add(packet_key)
        self.capacity_estimator.process_packet(slice_id=slice_id, pkt_size=packet_size, timestamp=timestamp)

    def end_epoch(self, epoch_duration):
        self.capacity_estimator.end_epoch()
        for slice_id in range(self.num_slices):
            slice_capacity = self.capacity_estimator.capacity_for(slice_id)
            rate_per_flow = [int(flow_bytes / epoch_duration) for flow_bytes in self.bytes_per_flow.values()]
            threshold = correct_threshold(rate_per_flow, slice_capacity)
            for flow_id in self.slice_to_flows[slice_id]:
                self.dropped_bytes_per_flow[flow_id] += max(self.bytes_per_flow[flow_id] - threshold, 0)
