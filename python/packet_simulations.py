import random
from collections import defaultdict
from typing import List, Tuple, Type

import numpy
import numpy as np
import matplotlib.pyplot as plt

from approx_qos import QosHistory, ApproxQosWithSavedStats
from heavy_hitters import ExactHeavyHitters, CountSketch, CountMinSketch

SEED = 0x12345678

"""
have X light streams and Y heavy streams
in each epoch, light streams send A packets and heavy streams send Y packets. Order them randomly. Create
arrays with duplicates to count as packets [X,X,X,X,Y,Y,Y,Y]. Shuffle them, then iterate and place them in a hash table
if the bucket is full, increment "drop count"
"""
MAX_INT = (1 << 32) - 1


def get_distinct_random_ints(count: int, min_val: int = 0, max_val: int = MAX_INT):
    if count > (max_val - min_val):
        return None
    if min_val > max_val:
        return None
    numbers = set([random.randint(min_val, max_val) for _ in range(count)])
    while len(numbers) < count:
        numbers.add(random.randint(min_val, max_val))
    return list(numbers)


def experiment_fixed_slice_demands(num_epochs: int,
                                   slice_weights: List[float],
                                   capacity: int):
    pass


def print_history_fairness(history: QosHistory):
    for slice_id in range(history.num_slices):
        print("Slice %d: " % slice_id, history.fairness_l2_history_for(slice_id))


def plot_history_fairness(history: QosHistory):
    fig, ax = plt.subplots()

    ax.set_title("Fairness for %d slices across %d epochs" % (history.num_slices, history.num_epochs))
    ax.set_ylabel("Fairness metric")
    ax.set_xlabel("EpochID")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    x_vals = list(range(history.num_epochs))
    for slice_id in range(history.num_slices):
        fairness_vals = history.fairness_mean_history_for(slice_id)
        line, = ax.plot(x_vals, fairness_vals, label="Slice %d" % slice_id, linewidth=1.0)

    ax.legend()
    plt.show()


def plot_threshold_error(history: QosHistory):
    fig, ax = plt.subplots()

    ax.set_title("Relative error in approximated threshold. %d slices, %d epochs"
                 % (history.num_slices, history.num_epochs))
    ax.set_ylabel("Relative error")
    ax.set_xlabel("EpochID")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    x_vals = list(range(history.num_epochs))
    for slice_id in range(history.num_slices):
        threshold_errors = history.threshold_error_for(slice_id)
        line, = ax.plot(x_vals, threshold_errors, label="Slice %d" % slice_id, linewidth=1.0)

    ax.legend()
    plt.show()


def plot_true_thresholds(history: QosHistory):
    fig, ax = plt.subplots()

    ax.set_title("Ideal and approximated thresholds over time. %d slices, %d epochs"
                 % (history.num_slices, history.num_epochs))
    ax.set_ylabel("Threshold")
    ax.set_xlabel("EpochID")

    ax.yaxis.grid(color='gray', linestyle='dashed')

    x_vals = list(range(history.num_epochs))
    for slice_id in range(history.num_slices):
        thresholds1 = [record[slice_id].threshold_ideal for record in history.history]
        line, = ax.plot(x_vals, thresholds1, label="Slice %d ideal threshold" % slice_id, linewidth=1.0)
        thresholds2 = [record[slice_id].threshold_chosen for record in history.history]
        line, = ax.plot(x_vals, thresholds2, label="Slice %d approx threshold" % slice_id, linewidth=1.0)

    ax.legend()
    plt.show()


def plot_drop_rate_scatter(history: QosHistory, sketch_used: Type, slice_weights: List[float]):
    fig, ax = plt.subplots()

    ax.set_title("Drop rate relative to normalized flow size,\n"
                 "sketch type %s, %d epochs" % (sketch_used.__name__, history.num_epochs))
    ax.set_ylabel("Drop rate")
    ax.set_xlabel("Per-epoch Flow size, normalized by the epoch's ideal threshold")
    # ax.set_xscale("log")

    largest_x_point: float = 0

    for slice_id in range(history.num_slices):
        points: List[Tuple[float, float]] = []
        # Chop off the first
        for epoch_record in history.history:
            slice_record = epoch_record[slice_id]
            for flow_size, flow_drops in zip(slice_record.flow_sizes, slice_record.flow_drops):
                relative_flow_size = flow_size / slice_record.threshold_ideal
                drop_rate = flow_drops / flow_size
                largest_x_point = max(largest_x_point, relative_flow_size)
                points.append((relative_flow_size, drop_rate))
        ax.scatter([x for x, y in points], [y for x, y in points], alpha=0.5,
                   label="Slice %d, weight %.3f" % (slice_id, slice_weights[slice_id]))
    reference_x = numpy.linspace(0.1, largest_x_point, num=100)
    reference_y = [max(x - 1, 0) / x for x in reference_x]
    ax.plot(reference_x, reference_y, label="Ideal drop rate", linewidth=1.0)
    ax.legend()
    plt.show()


def experiment_slowly_changing_flows():
    pass


def experiment_unstable_slice_demands(num_epochs: int,
                                      slice_weights: List[float],
                                      capacity: int,
                                      max_change_per_epoch: float,
                                      overload_factor: float,
                                      max_variance: float,
                                      sketch_class: Type,
                                      fixed_capacities: bool):
    zipf_exponent = 1.2
    rng = np.random.default_rng(SEED)
    qos = ApproxQosWithSavedStats(slice_weights=slice_weights,
                                  base_station_capacity=capacity,
                                  hh_instance=sketch_class(),
                                  fixed_capacities=fixed_capacities)

    initial_slice_loads = [int(weight * capacity * (1 + overload_factor)) for weight in slice_weights]
    curr_slice_loads = [load for load in initial_slice_loads]

    for epoch in range(num_epochs):
        print("Epoch", epoch)
        if max_change_per_epoch != 0.0:
            curr_slice_loads = [int(np.clip(initial_load * (1.0 - max_variance),
                                            load * random.uniform(1-max_change_per_epoch, 1+max_change_per_epoch),
                                            initial_load * (1.0 + max_variance)))
                                for load, initial_load in zip(curr_slice_loads, initial_slice_loads)]
        pkts = []
        for slice_id, slice_bytes in enumerate(curr_slice_loads):
            pkts.extend([(slice_id, int(pkt_id)) for pkt_id in rng.zipf(a=zipf_exponent, size=slice_bytes)])
        random.shuffle(pkts)

        for pkt in pkts:
            qos.process_packet(packet_size=1, packet_key=pkt, slice_id=pkt[0])
        qos.end_epoch()

    history = qos.get_history()
    history.trim_first_epochs(5)
    # plot_history_fairness(history)
    # plot_drop_rate_scatter(history, sketch_used=sketch_class, slice_weights=slice_weights)
    # plot_threshold_error(history)
    plot_true_thresholds(history)


if __name__ == "__main__":
    experiment_unstable_slice_demands(num_epochs=20,
                                      slice_weights=[0.5, 0.25, 0.125, 0.125],
                                      capacity=100000,
                                      overload_factor=0.1,
                                      max_change_per_epoch=0.01,
                                      max_variance=0.2,
                                      sketch_class=ExactHeavyHitters,
                                      fixed_capacities=False)
