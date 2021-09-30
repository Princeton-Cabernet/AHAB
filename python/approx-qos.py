#!/usr/bin/python3
import math
import random
from collections import defaultdict

from typing import List, Callable, Tuple, Optional, Dict, Set
import numpy as np
from heavy_hitters import HeavyHitterSketch, ExactHeavyHitters, CountMinSketch
from hashing import make_crc16_func
from estimators import ThresholdHistograms, ThresholdNewtonMethod, CapacityHistograms, correct_threshold

import matplotlib.pyplot as plt

SEED = 0x123456
random.seed(SEED)  # for reproducible tests


class ApproxQos:
    num_slices: int
    slice_weights: List[float]

    scale_factors: List[int]

    flow_size_sketch: HeavyHitterSketch
    true_flow_sizes: Dict[Tuple[int], int]
    threshold_estimators: List[ThresholdHistograms]
    capacity_estimator: CapacityHistograms

    dropped_bytes_per_flow: Dict[Tuple[int], int]

    def __init__(self, slice_weights: List[float], base_station_capacity: int,
                 hh_instance: Optional[HeavyHitterSketch]):
        self.num_slices = len(slice_weights)
        self.slice_weights = slice_weights.copy()

        if hh_instance is None:
            # Create a CMS sketch instance
            self.flow_size_sketch = CountMinSketch()
        else:
            # Allowing the passing of an existing HH sketch instance lets us share a sketch across ApproxQos instances,
            # which are currently per-base-station.
            self.flow_size_sketch = hh_instance

        self.threshold_estimators = [ThresholdNewtonMethod() for _ in range(self.num_slices)]
        self.capacity_estimator = CapacityHistograms(self.slice_weights, base_station_capacity)

        heaviest_weight = max(self.slice_weights)
        # there is no rounding error here if every weight is a power of 2, as will be the case in tofino
        self.scale_factors = [int(heaviest_weight / weight) for weight in self.slice_weights]

        self.dropped_bytes_per_flow = defaultdict(int)

    def process_packet(self, packet_size: int, slice_id: int, packet_key: Tuple[int]) -> bool:
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

    def end_epoch(self):
        self.capacity_estimator.end_epoch()
        for slice_id, estimator in enumerate(self.threshold_estimators):
            estimator.end_epoch(self.capacity_estimator.capacity_for(slice_id))
        self.flow_size_sketch.clear()


class ApproxQosWithSavedStats(ApproxQos):
    relative_flow_size_drop_rate_pairs: List[Tuple[float, float]]
    dropped_bytes_per_flow_this_epoch: Dict[Tuple[int], int]
    received_bytes_per_flow_this_epoch: Dict[Tuple[int], int]
    slice_to_flows: Dict[int, Set[Tuple[int]]]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

        self.relative_flow_size_drop_rate_pairs = []
        self.clear_per_epoch_structs()

    def clear_per_epoch_structs(self):
        self.dropped_bytes_per_flow_this_epoch = defaultdict(int)
        self.received_bytes_per_flow_this_epoch = defaultdict(int)
        self.slice_to_flows = defaultdict(set)

    def process_packet(self, packet_size: int, slice_id: int, packet_key: Tuple[int]) -> bool:
        drop = super().process_packet(packet_size, slice_id, packet_key)

        self.received_bytes_per_flow_this_epoch[packet_key] += packet_size
        if drop:
            self.dropped_bytes_per_flow_this_epoch[packet_key] += packet_size
        self.slice_to_flows[slice_id].add(packet_key)

        return drop

    def end_epoch(self):
        super().end_epoch()
        flow_sizes = self.received_bytes_per_flow_this_epoch
        for slice_id in range(self.num_slices):
            capacity = self.capacity_estimator.capacity_for(slice_id)
            flow_ids = self.slice_to_flows[slice_id]
            true_threshold = correct_threshold([flow_sizes[flow_id] for flow_id in flow_ids], capacity)
            for flow_id in flow_ids:
                flow_size = flow_sizes[flow_id]
                dropped_bytes = self.dropped_bytes_per_flow_this_epoch[flow_id]
                relative_flow_size = flow_size / true_threshold
                drop_rate = dropped_bytes / flow_size

                self.relative_flow_size_drop_rate_pairs.append((relative_flow_size, drop_rate))

        self.clear_per_epoch_structs()


class PerfectQos:
    num_slices: int
    slice_weights: List[float]
    total_capacity: int

    bytes_per_flow: Dict[Tuple[int], int]
    slice_to_flows: Dict[int, Set[Tuple[int]]]

    capacity_estimator: CapacityHistograms

    dropped_bytes_per_flow: Dict[Tuple[int], int]

    def __init__(self, slice_weights: List[float], base_station_capacity: int):
        self.total_capacity = base_station_capacity
        self.clear_per_window_structs()
        self.capacity_estimator = CapacityHistograms(self.slice_weights, base_station_capacity)

    def clear_per_window_structs(self):
        self.bytes_per_flow = defaultdict(int)
        self.slice_to_flows = defaultdict(set)

    def process_packet(self, packet_key: Tuple[int], packet_size: int, slice_id: int):
        self.bytes_per_flow[packet_key] += packet_size
        self.slice_to_flows[slice_id].add(packet_key)
        self.capacity_estimator.process_packet(slice_id=slice_id, pkt_size=packet_size)

    def end_epoch(self):
        self.capacity_estimator.end_epoch()
        for slice_id in range(self.num_slices):
            slice_capacity = self.capacity_estimator.capacity_for(slice_id)
            threshold = correct_threshold(list(self.bytes_per_flow.values()), self.total_capacity)
            for flow_id in self.slice_to_flows[slice_id]:
                self.dropped_bytes_per_flow[flow_id] += max(self.bytes_per_flow[flow_id] - threshold, 0)



