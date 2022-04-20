import random
from collections import defaultdict
from typing import List, Tuple, Type

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.axes import Axes

from approx_qos import QosHistory, ApproxQosWithSavedStats
from heavy_hitters import ExactHeavyHitters, CountSketch, CountMinSketch, HeavyHitterSketch

from plots import plot_thresholds, plot_threshold_error, plot_slice_loads, plot_slice_flow_counts, \
    plot_history_fairness, plot_drop_rate_scatter
from rate_estimators import RateEstimator, LpfMinSketch

from common import SEED, LPF_SCALE, LPF_DECAY

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


def experiment_slowly_changing_flows():
    pass


def experiment_unstable_slice_demands(num_epochs: int,
                                      slice_weights: List[float],
                                      capacity: int,
                                      max_change_per_epoch: float,
                                      subscription_factor: float,
                                      max_variance: float,
                                      sketch_class: Type[RateEstimator],
                                      fixed_capacities: bool,
                                      packet_spacing: int):
    zipf_exponent = 1.2
    rng = np.random.default_rng(SEED)
    qos = ApproxQosWithSavedStats(slice_weights=slice_weights,
                                  vtrunk_capacity=capacity,
                                  rate_estimator=sketch_class(),
                                  fixed_capacities=fixed_capacities)

    initial_slice_loads = [int(weight * capacity * subscription_factor) for weight in slice_weights]
    curr_slice_loads = [load for load in initial_slice_loads]

    current_time = 0
    for epoch in range(num_epochs):
        print("Epoch", epoch)
        if max_change_per_epoch != 0.0:
            curr_slice_loads = [int(np.clip(initial_load * (1.0 - max_variance),
                                            load * random.uniform(1-max_change_per_epoch, 1+max_change_per_epoch),
                                            initial_load * (1.0 + max_variance)))
                                for load, initial_load in zip(curr_slice_loads, initial_slice_loads)]
        pkts = []
        for slice_id, slice_bytes in enumerate(curr_slice_loads):
            # make packetIDs wacky so they have more bits and are more spread out before hashing
            pkts.extend([(slice_id, int(pkt_id) * 521)
                         for pkt_id in rng.zipf(a=zipf_exponent, size=slice_bytes)])
        random.shuffle(pkts)

        for i, pkt in enumerate(pkts):
            qos.process_packet(packet_size=1000, packet_key=pkt, slice_id=pkt[0],
                               packet_timestamp=packet_spacing*current_time)
            current_time += 1
        qos.end_epoch()

    history = qos.get_history()
    history.trim_first_epochs(5)
    fig, axes = plt.subplots(3, 2)
    fig.tight_layout()
    fig.suptitle("%d Slices, %d Epoch, %s, Traffic zipf exp: %.2f,\n"
                 "Max traffic change per-epoch: %.1f%%, Subscription factor: %d%%"
                 % (history.num_slices, history.num_epochs, sketch_class.__name__,
                    zipf_exponent, max_change_per_epoch * 100, int(subscription_factor * 100)))
    slice_colors = ["red", "green", "blue", "purple"]
    plot_slice_loads(axes[0, 0], slice_colors, history)
    plot_slice_flow_counts(axes[0, 1], slice_colors, history)
    plot_thresholds(axes[1, 0], slice_colors, history)
    plot_drop_rate_scatter(axes[1, 1], slice_colors, history, slice_weights=slice_weights)
    plot_threshold_error(axes[2, 0], slice_colors, history)
    plot_history_fairness(axes[2, 1], slice_colors, history)

    plt.subplots_adjust(top=0.90)
    plt.show()


if __name__ == "__main__":
    experiment_unstable_slice_demands(num_epochs=10,
                                      slice_weights=[0.5, 0.25, 0.125, 0.125],
                                      capacity=100000,
                                      subscription_factor=1.2,
                                      max_change_per_epoch=0.02,
                                      max_variance=0.2,
                                      sketch_class=LpfMinSketch,
                                      fixed_capacities=False,
                                      packet_spacing=1)
