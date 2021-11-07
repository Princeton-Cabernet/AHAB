from abc import ABC, abstractmethod
from collections import defaultdict

import numpy as np
from matplotlib import pyplot as plt

from hashing import make_crc16_func, CRC16_DEFAULT_POLY
from typing import List, Callable, Tuple, Dict, Optional
from statistics import mean
import math
import random
from matplotlib.axes import Axes

from heavy_hitters import CountMinSketch

FlowId = Tuple[int, ...]
Packet = Tuple[int, int, FlowId]  # (timestamp_us, packet_len, flow_id)
SEED = 0x12345678


def compute_sample_lpf(prev_lpf_val: int, curr_sample: int,
                       prev_timestamp: int, curr_timestamp: int, time_constant: int) -> int:
    """ Based upon tofino LPF sample mode documentation """
    exponent = -(curr_timestamp - prev_timestamp) / time_constant
    return int(prev_lpf_val + (curr_sample - prev_lpf_val) * (1 - math.pow(math.e, exponent)))


def compute_rate_lpf(prev_lpf_val: int, curr_sample: int,
                     prev_timestamp: int, curr_timestamp: int, time_constant: int) -> int:
    """ Based upon tofino LPF rate mode documentation """
    exponent = -(curr_timestamp - prev_timestamp) / time_constant
    return int(curr_sample + prev_lpf_val * math.pow(math.e, exponent))


class LpfRegister(ABC):
    @abstractmethod
    def update(self, key: FlowId, timestamp: int, value: int) -> int:
        return NotImplemented

    @abstractmethod
    def get(self, key: FlowId) -> int:
        return NotImplemented


class LpfExactRegister(LpfRegister):
    # Each LPF cell consists of two values: the timestamp of the last sample, and the current LPF value
    timestamps: Dict[FlowId, int]
    values: Dict[FlowId, int]
    time_constant: int
    scale_down_factor: int

    def __init__(self, time_constant: int, scale_down_factor: int = 0):
        self.timestamps = defaultdict(int)
        self.values = defaultdict(int)
        self.time_constant = time_constant
        self.scale_down_factor = scale_down_factor

    def update(self, key: FlowId, timestamp: int, value: int) -> int:
        new_val = compute_rate_lpf(self.values[key], value, self.timestamps[key], timestamp, self.time_constant)
        self.timestamps[key] = timestamp
        self.values[key] = new_val
        return new_val >> self.scale_down_factor

    def get(self, key: FlowId) -> int:
        return self.values[key] >> self.scale_down_factor


class LpfHashedRegister(LpfRegister):
    # Each LPF cell consists of two values: the timestamp of the last sample, and the current LPF value
    timestamps: List[int]
    values: List[int]
    hash_func: Callable[..., int]
    height: int
    time_constant: int
    scale_down_factor: int

    def __init__(self, time_constant: int, height: int, hash_func: Callable[..., int], scale_down_factor: int = 0):
        self.timestamps = [0] * height
        self.values = [0] * height
        self.hash_func = hash_func
        self.height = height
        self.time_constant = time_constant
        self.scale_down_factor = scale_down_factor

    def __index_of(self, key: FlowId):
        return self.hash_func(*key) % self.height

    def update(self, key: FlowId, timestamp: int, value: int):
        index = self.__index_of(key)
        new_val = compute_rate_lpf(self.values[index], value, self.timestamps[index], timestamp, self.time_constant)
        self.timestamps[index] = timestamp
        self.values[index] = new_val
        return new_val >> self.scale_down_factor

    def get(self, key: FlowId):
        return self.values[self.__index_of(key)] >> self.scale_down_factor


class LpfMinSketch(LpfRegister):
    """
    Count-min sketch with LPFs instead of counters
    """
    width: int
    height: int
    registers: List[LpfRegister]

    def __init__(self, time_constant: int, width: int, height: int):
        self.width = width
        self.height = height

        hash_funcs = [make_crc16_func(polynomial=CRC16_DEFAULT_POLY + (0x100 * i)) for i in range(width)]
        self.registers = [LpfHashedRegister(time_constant=time_constant,
                                            height=height,
                                            hash_func=hash_func) for hash_func in hash_funcs]

    def update(self, key: FlowId, timestamp: int, value: int):
        return min(reg.update(key, timestamp, value) for reg in self.registers)

    def get(self, key: FlowId):
        return min(reg.get(key) for reg in self.registers)


def plot_lpf_rate_convergence():
    # over how many nanoseconds do we want an average
    time_constant = 16000  # 16 ms
    pkt_size = 100  # 100 bytes
    pkt_count = 100
    lpf = LpfExactRegister(time_constant)

    # one packet every ms for half the experiment, then one every 2ms for the second half
    # byterate should be 100 bytes per ms and then 50 bytes per ms
    timestamps = [1000 * (i + max(0, i - (pkt_count // 2))) for i in range(pkt_count)]

    lpf_outputs = []
    for timestamp in timestamps:
        lpf_outputs.append(lpf.update(key=(1,), timestamp=timestamp, value=pkt_size))

    fig, ax = plt.subplots(1)
    ax.plot(list(range(pkt_count)), lpf_outputs)
    plt.show()


def plot_lms_rate_convergence():
    # over how many nanoseconds do we want an average
    time_constant = 16000  # 16 ms
    pkt_size = 100  # 100 bytes
    pkt_count = 100
    lpf = LpfExactRegister(time_constant)

    # one packet every ms for half the experiment, then one every 2ms for the second half
    # byterate should be 100 bytes per ms and then 50 bytes per ms
    timestamps = [1000 * (i + max(0, i - (pkt_count // 2))) for i in range(pkt_count)]

    lpf_outputs = []
    for timestamp in timestamps:
        lpf_outputs.append(lpf.update(key=(1,), timestamp=timestamp, value=pkt_size))

    fig, ax = plt.subplots(1)
    ax.plot(list(range(pkt_count)), lpf_outputs)
    plt.show()


def get_epoched_cms_approx_pairs(packets: List[Packet],
                                 cms_width: int, cms_height: int, epoch_duration: int) -> List[Tuple[int, int]]:
    cms = CountMinSketch(width=cms_width, height=cms_height)
    exact_count = defaultdict(int)

    result_pairs: List[Tuple[int, int]] = []
    last_reset_timestamp = packets[0][0]
    for timestamp, pkt_size, flow_id in packets:
        if timestamp - last_reset_timestamp > epoch_duration:
            cms.clear()
            exact_count.clear()
            last_reset_timestamp = timestamp
        cms_val = cms.add(flow_id, pkt_size)
        exact_count[flow_id] += pkt_size
        exact_val = exact_count[flow_id]
        result_pairs.append((exact_val, cms_val))

    return result_pairs


def get_approx_pairs(packets: List[Packet],
                     lms_width: int, lms_height: int, time_constant: int) -> List[Tuple[int, int]]:
    lms = LpfMinSketch(time_constant=time_constant, width=lms_width, height=lms_height)
    lpf = LpfExactRegister(time_constant=time_constant)

    result_pairs: List[Tuple[int, int]] = []
    for timestamp, pkt_size, flow_id in packets:
        lpf_val = lpf.update(flow_id, timestamp, pkt_size)
        lms_val = lms.update(flow_id, timestamp, pkt_size)
        result_pairs.append((lpf_val, lms_val))

    return result_pairs


def get_approx_pairs_averaged(packets: List[Packet],
                              lms_width: int, lms_height: int, time_constant: int) -> List[Tuple[int, int]]:
    lms = LpfMinSketch(time_constant=time_constant, width=lms_width, height=lms_height)
    lpf = LpfExactRegister(time_constant=time_constant)

    results: Dict[FlowId, List[Tuple[int, int]]] = defaultdict(list)

    for timestamp, pkt_size, flow_id in packets:
        lpf_val = lpf.update(flow_id, timestamp, pkt_size)
        lms_val = lms.update(flow_id, timestamp, pkt_size)
        results[flow_id].append((lpf_val, lms_val))

    result_pairs: List[Tuple[int, int]] = []
    for flow_id, pair_list in results.items():
        lpf_avg = mean([x for x, y in pair_list])
        lms_avg = mean([y for x, y in pair_list])
        result_pairs.append((lpf_avg, lms_avg))

    return result_pairs


def plot_approx_pairs(pairs: List[Tuple[int, int]], title: str, ax: Optional[Axes] = None):
    x_vals = [x for x, y in pairs]
    y_vals = [y for x, y in pairs]

    if ax is None:
        fig, ax = plt.subplots(1)
    ax.scatter(x_vals, y_vals, alpha=0.3)
    #  ax.set_xscale("log", base=10)
    #  ax.set_yscale("log", base=10)
    ax.set_xlabel("Ground Truth")
    ax.set_ylabel("Sketch Output")
    ax.set_title(title)
    if ax is None:
        plt.show()


def plot_zipf_accuracy(cms=False):
    time_constant = 5
    struct_width = 3
    struct_height = 512
    num_pkts = 1000000
    zipf_exponent = 1.2
    rng = np.random.default_rng(SEED)

    # Inflate the packet-IDs to spread them out more
    packets = [(i,  # timestamp
                random.randint(20, 200),  # packet size
                (int(pkt_id) * 521, int(pkt_id), int(pkt_id) * 91))  # flow ID
               for i, pkt_id in enumerate(rng.zipf(a=zipf_exponent, size=num_pkts))]

    results1 = get_epoched_cms_approx_pairs(packets,
                                            struct_width,
                                            struct_height,
                                            time_constant)

    results2 = get_approx_pairs(packets,
                                struct_width,
                                struct_height,
                                time_constant)

    plt.rcParams['figure.figsize'] = [10, 5]
    fig, (ax1, ax2) = plt.subplots(1, 2)

    fig.suptitle("Accuracy of Epoched-CMS and Decaying-CMS\n "
                 "%d rows, %d cols, %d time constant\n"
                 "%d packets generated from zipfian distribution with exponent %.1f"
                 % (struct_height, struct_width, time_constant, num_pkts, zipf_exponent))

    plot_approx_pairs(results1, "Epoched-CMS", ax1)
    plot_approx_pairs(results2, "Decaying-CMS", ax2)

    fig.tight_layout()
    plt.subplots_adjust(top=0.80)
    plt.show()


def plot_uniform_accuracy():
    time_constant = 100
    struct_width = 3
    struct_height = 2048
    num_flows = 10000
    num_pkts = 1000000

    packets = [(i,  # timestamp
                random.randint(20, 200),  # packet size
                (random.randint(0, num_flows) * 91,))  # flow ID
               for i in range(num_pkts)]

    results1 = get_epoched_cms_approx_pairs(packets,
                                            struct_width,
                                            struct_height,
                                            time_constant)

    results2 = get_approx_pairs(packets,
                                struct_width,
                                struct_height,
                                time_constant)

    plt.rcParams['figure.figsize'] = [10, 5]
    fig, (ax1, ax2) = plt.subplots(1, 2)

    fig.suptitle("Accuracy of Epoched-CMS and Decaying-CMS\n "
                 "%d rows, %d cols, %d time constant\n"
                 "%d packets uniformly generated from %d possible flows"
                 % (struct_height, struct_width, time_constant, num_pkts, num_flows))

    plot_approx_pairs(results1, "Epoched-CMS", ax1)
    plot_approx_pairs(results2, "Decaying-CMS", ax2)

    fig.tight_layout()
    plt.subplots_adjust(top=0.80)
    plt.show()


if __name__ == "__main__":
    plot_zipf_accuracy()
    #plot_uniform_accuracy()
