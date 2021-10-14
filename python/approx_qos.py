#!/usr/bin/python3
import random
from collections import defaultdict
from dataclasses import dataclass

from typing import List, Tuple, Optional, Dict, Set, Type
from heavy_hitters import HeavyHitterSketch, ExactHeavyHitters, CountMinSketch
from estimators import ThresholdEstimator, ThresholdHistograms, \
    ThresholdNewtonMethodTofino, CapacityHistograms, correct_threshold, CapacityEstimator, CapacityFixed
import numpy as np
from statistics import mean

SEED = 0x123456
random.seed(SEED)  # for reproducible tests

FlowId = Tuple[int, ...]


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

    def drop_rates_per_relative_flow_size(self) -> dict[float, float]:
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

    scale_factors: List[int]

    flow_size_sketch: HeavyHitterSketch
    true_flow_sizes: Dict[FlowId, int]
    threshold_estimators: List[ThresholdEstimator]
    capacity_estimator: CapacityEstimator

    dropped_bytes_per_flow: Dict[FlowId, int]

    def __init__(self, slice_weights: List[float],
                 base_station_capacity: int,
                 hh_instance: Optional[HeavyHitterSketch] = None,
                 threshold_estimator_class: Type = ThresholdNewtonMethodTofino,
                 fixed_capacities: bool = False):
        self.num_slices = len(slice_weights)
        self.slice_weights = slice_weights.copy()

        if hh_instance is None:
            # Create a CMS sketch instance
            self.flow_size_sketch = CountMinSketch()
        else:
            # Allowing the passing of an existing HH sketch instance lets us share a sketch across ApproxQos instances,
            # which are currently per-base-station.
            self.flow_size_sketch = hh_instance

        self.threshold_estimators = [threshold_estimator_class() for _ in range(self.num_slices)]
        if fixed_capacities:
            self.capacity_estimator = CapacityFixed(self.slice_weights, base_station_capacity)
        else:
            self.capacity_estimator = CapacityHistograms(self.slice_weights, base_station_capacity)
        for slice_id, estimator in enumerate(self.threshold_estimators):
            # Initial threshold for each slice is capacity divided by 4. Its arbitrary
            estimator.set_threshold(int(self.capacity_estimator.capacity_for(slice_id) / 6))

        heaviest_weight = max(self.slice_weights)
        # there is no rounding error here if every weight is a power of 2, as will be the case in tofino
        self.scale_factors = [int(heaviest_weight / weight) for weight in self.slice_weights]

        self.dropped_bytes_per_flow = defaultdict(int)
        self.__post_init__()

    def __post_init__(self):
        pass

    def process_packet(self, packet_size: int, slice_id: int, packet_key: FlowId) -> bool:
        scale_factor = self.scale_factors[slice_id]
        scaled_size = packet_size * scale_factor
        estimated_flow_size = int(self.flow_size_sketch.add_after_return(packet_key, scaled_size) / scale_factor)
        threshold = self.threshold_estimators[slice_id].get_current_threshold()
        drop: bool = estimated_flow_size > threshold
        if drop:
            self.dropped_bytes_per_flow[packet_key] += packet_size

        self.threshold_estimators[slice_id].process_packet(packet_size, estimated_flow_size)
        self.capacity_estimator.process_packet(slice_id=slice_id, pkt_size=packet_size)

        return drop

    def end_epoch(self) -> None:
        self.capacity_estimator.end_epoch()
        for slice_id, estimator in enumerate(self.threshold_estimators):
            estimator.end_epoch(self.capacity_estimator.capacity_for(slice_id))
        self.flow_size_sketch.clear()


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

    def process_packet(self, packet_size: int, slice_id: int, packet_key: FlowId) -> bool:
        drop = super().process_packet(packet_size, slice_id, packet_key)

        self.received_bytes_per_flow_this_epoch[packet_key] += packet_size
        if drop:
            self.dropped_bytes_per_flow_this_epoch[packet_key] += packet_size
        self.slice_to_flows[slice_id].add(packet_key)

        return drop

    def end_epoch(self) -> None:
        # Save the thresholds and capacities from this epoch
        chosen_thresholds = [estimator.get_current_threshold() for estimator in self.threshold_estimators]
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
                                                 threshold_chosen=chosen_thresholds[slice_id],
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
        self.clear_per_window_structs()
        self.capacity_estimator = CapacityHistograms(self.slice_weights, base_station_capacity)

    def clear_per_window_structs(self):
        self.bytes_per_flow = defaultdict(int)
        self.slice_to_flows = defaultdict(set)

    def process_packet(self, packet_key: FlowId, packet_size: int, slice_id: int):
        self.bytes_per_flow[packet_key] += packet_size
        self.slice_to_flows[slice_id].add(packet_key)
        self.capacity_estimator.process_packet(slice_id=slice_id, pkt_size=packet_size)

    def end_epoch(self):
        self.capacity_estimator.end_epoch()
        for slice_id in range(self.num_slices):
            slice_capacity = self.capacity_estimator.capacity_for(slice_id)
            threshold = correct_threshold(list(self.bytes_per_flow.values()), slice_capacity)
            for flow_id in self.slice_to_flows[slice_id]:
                self.dropped_bytes_per_flow[flow_id] += max(self.bytes_per_flow[flow_id] - threshold, 0)
