#!/usr/bin/python3
import math
import random
from collections import defaultdict

from typing import List, Callable, Tuple, Optional, Dict
import numpy as np
from heavy_hitters import HeavyHitterSketch, ExactHeavyHitters, CountMinSketch
from hashing import make_crc16_func
from estimators import ThresholdHistograms, CapacityHistograms

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

    drops: Dict[Tuple[int], int]

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

        self.threshold_estimators = [ThresholdHistograms() for _ in range(self.num_slices)]
        self.capacity_estimator = CapacityHistograms(self.slice_weights, base_station_capacity)

        heaviest_weight = max(self.slice_weights)
        self.scale_factors = [int(heaviest_weight / weight) for weight in self.slice_weights]

        self.drops = defaultdict(int)

    def process_packet(self, packet_size: int, slice_id: int, packet_key: Tuple[int]):
        scaled_size = packet_size * self.scale_factors[slice_id]
        flow_size = self.flow_size_sketch.return_then_add(packet_key, scaled_size)
        threshold = self.threshold_estimators[slice_id].get_current_threshold()
        if flow_size > threshold:
            self.drops[packet_key] += 1

        self.threshold_estimators[slice_id].process_packet(scaled_size, flow_size)
        self.capacity_estimator.process_packet(slice_id=slice_id, pkt_size=packet_size)

    def end_epoch(self):
        self.capacity_estimator.end_epoch()
        for slice_id, estimator in enumerate(self.threshold_estimators):
            estimator.end_epoch(self.capacity_estimator.capacity_for(slice_id))
        self.flow_size_sketch.clear()




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


def experiment():
    """
    Experiment using zipf distribution across flow sizes
    :return:
    """
    zipf_exponent = 1.2
    epochs = 10
    link_capacity = 200000
    packets_per_epoch = int(link_capacity * 1.2)

    slice_weights = [2**(-1), 2**(-2), 2**(-3), 2**(-3)]
    num_slices = len(slice_weights)

    drops = defaultdict(int)
    flow_sizes = defaultdict(int)

    rng = np.random.default_rng(SEED)

    for epoch in range(epochs):
        print("Epoch:", epoch)

        packets = rng.zipf(a=zipf_exponent, size=packets_per_epoch)

        for packet in packets:
            flow_sizes[packet] += 1
            epoch_salt = (epoch & 0xffff) << (_crc16(packet) % 16)
            if cms.add(packet, pepper=epoch_salt) > bucket_threshold:
                drops[packet] += 1

    print("Flows:", len(flow_sizes))

    drop_rates = [(flow_size / epochs, drops[packet]/flow_size) for packet, flow_size in flow_sizes.items()]
    drop_rates.sort(key=lambda tup: tup[0])

    x = [a for (a, b) in drop_rates]
    y = [b for (a, b) in drop_rates]

    num_light_flows = 0
    light_flows_with_bad_drops = 0

    for (flow_size, drop_rate) in drop_rates:
        if flow_size < bucket_threshold:
            num_light_flows += 1
            if drop_rate > 0.01:
                light_flows_with_bad_drops += 1
    print("%d light flows, %d have bad drop rates"
          % (num_light_flows, light_flows_with_bad_drops))


    fig, ax = plt.subplots()

    ax.set_title("%d flows, %d epochs, %d per-epoch bucket capacity"
                 % (len(flow_sizes), epochs, bucket_threshold))
    ax.set_ylabel("Drop rate")
    ax.set_xlabel("Flow size (packets per epoch)")
    ax.set_xscale("log")

    ax.scatter(x, y, alpha=0.5)
    plt.show()


def experiment():
    clever = True
    COLUMNS = 2
    ROWS = 65536 // COLUMNS
    BUCKET_THRESHOLD = 100
    LIGHT_STREAMS = 500000
    LIGHT_STREAM_RATE = 10
    HEAVY_STREAMS = 10
    HEAVY_STREAM_RATE = 10000

    ITERATIONS = 10

    lightStreamDrops = 0
    heavyStreamDrops = 0

    cms: Optional[CountMinSketch] = None
    buckets: Optional[List[int]] = None

    if clever:
        print("Using count-min sketch")
        hash_funcs = [make_crc16_func(polynomial=CRC16_DEFAULT_POLY + (0x100 * i)) for i in range(COLUMNS)]
        salts = [random.randint(0, MAX_INT) for _ in range(COLUMNS)]
        cms = CountMinSketch(hash_funcs=hash_funcs, salts=salts, height=ROWS)
    else:
        print("Using simple buckets")



    print("Generating random flow IDs")
    flowIds = get_distinct_random_ints(LIGHT_STREAMS + HEAVY_STREAMS)
    print("Done")

    light_flow_ids = set(flowIds[:LIGHT_STREAMS])
    heavy_flow_ids = set(flowIds[LIGHT_STREAMS + 1:])

    drops = defaultdict(int)

    for iteration in range(ITERATIONS):
        print("Iteration %d" % iteration)
        # clear the buckets for a new epoch
        if clever:
            cms.clear()
        else:
            buckets = [0] * COLUMNS

        # generate "packets"
        packets = []
        for key in light_flow_ids:
            packets.extend([key] * LIGHT_STREAM_RATE)
        for key in heavy_flow_ids:
            packets.extend([key] * HEAVY_STREAM_RATE)
        random.shuffle(packets)

        # iterate through
        for flowId in packets:
            drop = False
            epoch_salt = (iteration & 0xffff) << (_crc16(flowId) % 16)
            if clever:
                if cms.add(flowId, epoch_salt) > BUCKET_THRESHOLD:
                    drop = True
            else:
                index = _crc16(flowId, epoch_salt)
                buckets[index] += 1
                if buckets[index] > BUCKET_THRESHOLD:
                    drop = True
            if drop:
                drops[flowId] += 1

    print("Done iterating")

    lightDropRates = []
    heavyDropRates = []
    for key in light_flow_ids:
        dropRate = drops[key] / (LIGHT_STREAM_RATE * ITERATIONS)
        lightDropRates.append(dropRate)
        lightDropRates.sort()
    for key in heavy_flow_ids:
        dropRate = drops[key] / (HEAVY_STREAM_RATE * ITERATIONS)
        heavyDropRates.append(dropRate)
        heavyDropRates.sort()

    def get_percent_slots(array: List, percents: List[float]):
        return tuple([array[min(math.floor(len(array) * percent), len(array) - 1)] for percent in percents])

    nonZeroLightDropRates = []
    for i in range(len(lightDropRates)):
        if lightDropRates[i] > 0.0:
            nonZeroLightDropRates = lightDropRates[i:]
            break

    print("%d light flows of %d had non-zero drops" % (len(nonZeroLightDropRates), LIGHT_STREAMS))
    print("Light drop rates: ...", lightDropRates[-20:])
    print("Heavy drop rates:", heavyDropRates)
    print("Light drop rates: 90%%: %f, 95%%: %f, 99%%: %f, 99.9%%: %f, 99.99%%: %f, 100%%: %f"
          % get_percent_slots(lightDropRates, [0.9, 0.95, 0.99, 0.999, 0.9999, 1.0]))


    fig, ax = plt.subplots()

    ax.set_title("%d light flows, %d heavy flows, %d epochs, %d bucket threshold"
                 % (LIGHT_STREAMS, HEAVY_STREAMS, ITERATIONS, BUCKET_THRESHOLD))
    ax.set_ylabel("Drop rate")
    ax.set_xlabel("Light flow index")

    # Using set_dashes() to modify dashing of an existing line
    line1, = ax.plot([_ for _ in range(len(lightDropRates))], lightDropRates, label='Light flow drop rates')
    line1.set_dashes([2, 2, 10, 2])  # 2pt line, 2pt break, 10pt line, 2pt break

    # Using plot(..., dashes=...) to set the dashing when creating a line
    # line2, = ax.plot(x, y - 0.2, dashes=[6, 2], label='Using the dashes parameter')

    ax.legend()
    plt.show()



if __name__ == "__main__":
    experiment2()
