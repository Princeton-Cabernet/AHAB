from abc import ABC, abstractmethod
from collections import defaultdict

import numpy as np
from matplotlib import pyplot as plt

from hashing import make_crc16_func, CRC16_DEFAULT_POLY
from typing import List, Callable, Tuple, Dict
import math
import random

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

        hash_funcs = [make_crc16_func(polynomial=CRC16_DEFAULT_POLY + (0x111 * i)) for i in range(width)]
        self.registers = [LpfHashedRegister(time_constant=time_constant,
                                            height=height,
                                            hash_func=hash_func) for hash_func in hash_funcs]

    def update(self, key: FlowId, timestamp: int, value: int):
        return min(reg.update(key, timestamp, value) for reg in self.registers)

    def get(self, key: FlowId):
        return min(reg.get(key) for reg in self.registers)


def plot_rate_convergence():
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


def get_approx_pairs(packets: List[Packet],
                     lms_width: int, lms_height: int, time_constant: int) -> List[Tuple[int, int]]:
    lms = LpfMinSketch(time_constant=time_constant, width=lms_width, height=lms_height)
    lpf = LpfExactRegister(time_constant=time_constant)

    result_pairs: List[Tuple[int, int]] = []
    for timestamp, pkt_size, flow_id in packets:
        lms_val = lms.update(flow_id, timestamp, pkt_size)
        lpf_val = lpf.update(flow_id, timestamp, pkt_size)
        result_pairs.append((lpf_val, lms_val))

    return result_pairs


def plot_approx_pairs(pairs: List[Tuple[int, int]], title: str):
    x_vals = [x for x, y in pairs]
    y_vals = [y for x, y in pairs]

    fig, ax = plt.subplots(1)
    ax.scatter(x_vals, y_vals, alpha=0.3)
    ax.set_xlabel("LPF Ground Truth Value")
    ax.set_ylabel("LPF-Min-Sketch Value")
    ax.set_title(title)
    plt.show()


def plot_zipf_accuracy():
    time_constant = 5
    lms_width = 3
    lms_height = 512
    pkt_size = 100
    num_pkts = 1000000
    zipf_exponent = 1.2
    rng = np.random.default_rng(SEED)

    # Inflate the packet-IDs to spread them out more
    packets = [(i,  # timestamp
                pkt_size,  # packet size
                (int(pkt_id) * 521, int(pkt_id), int(pkt_id) * 91))  # flow ID
               for i, pkt_id in enumerate(rng.zipf(a=zipf_exponent, size=num_pkts))]

    results = get_approx_pairs(packets=packets,
                               lms_width=lms_width,
                               lms_height=lms_height,
                               time_constant=time_constant)

    title = "Accuracy of a \"LPF-Min-Sketch\" with %d rows and %d cols\n " \
            "%d packets generated from zipfian distribution with exponent %.1f" \
            % (lms_height, lms_width, num_pkts, zipf_exponent)

    plot_approx_pairs(results, title)


def plot_uniform_accuracy():
    time_constant = 5
    lms_width = 3
    lms_height = 512
    num_flows = 10000
    num_pkts = 1000000

    packets = [(i,  # timestamp
                random.randint(20, 200),  # packet size
                (random.randint(0, num_flows) * 91,))  # flow ID
               for i in range(num_pkts)]

    results = get_approx_pairs(packets=packets,
                               lms_width=lms_width,
                               lms_height=lms_height,
                               time_constant=time_constant)

    title = "Accuracy of a \"LPF-Min-Sketch\" with %d rows and %d cols\n "\
            "%d packets uniformly generated from %d possible flows" \
            % (lms_height, lms_width, num_pkts, num_flows)

    plot_approx_pairs(results, title)


if __name__ == "__main__":
    #plot_zipf_accuracy()
    plot_uniform_accuracy()
