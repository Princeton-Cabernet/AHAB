#!/usr/bin/python3
import random
from collections import defaultdict
from functools import partial
from typing import List, Callable, Tuple, Optional, Dict, Iterable

import networkx as nx

import crcmod

random.seed(0x12345)  # for reproducible tests

CRC16_DEFAULT_POLY = 0x18005


def run_crcmod_func(crc_func: Callable[[bytes], int], *nums: int) -> int:
    """
    Pass inputs to the CRC function and return the output
    :param crc_func: CRC function created using crcmod.mkCrcFun
    :param nums: CRC inputs
    :return: CRC output
    """
    crc_input = bytes(0)
    for num in nums:
        crc_input += num.to_bytes((num.bit_length() + 7) // 8, byteorder='big')
    return crc_func(crc_input)


def make_crc16_func(polynomial: int = CRC16_DEFAULT_POLY, salt=0) -> Callable[..., int]:
    """
    Given a CRC polynomial (and optionally a salt), return a function for computing CRC outputs
    :param polynomial: the CRC polynomial
    :param salt: the CRC salt
    :return: a CRC function
    """
    return partial(run_crcmod_func, crcmod.mkCrcFun(poly=polynomial, initCrc=0), salt)


CRC16 = make_crc16_func(polynomial=CRC16_DEFAULT_POLY)


class CompactHashThing:
    """
    Some weird data structure based upon ideas from the Broom Filter paper. Ask Danny
    """
    signatures: List[List[int]]
    values:     List[List[int]]
    stages: int
    width: int
    index_hash_funcs: List[Callable[..., int]]
    signature_hash_funcs: List[Callable[..., int]]
    ground_truth: Dict[int, int]

    key_width: int
    max_key: int
    value_width: int
    max_value: int
    signature_width: int
    signature_mask: int

    keys_assigned: bool = False
    g: nx.DiGraph

    def __init__(self, index_hash_funcs: List[Callable[..., int]],
                 signature_hash_funcs: List[Callable[..., int]],
                 width: int = 65536,
                 key_width: int = 24,
                 value_width: int = 6,
                 signature_width: int = 2):

        self.width = width
        self.stages = len(index_hash_funcs)

        assert(len(signature_hash_funcs) == len(index_hash_funcs))
        self.signature_hash_funcs = signature_hash_funcs
        self.index_hash_funcs = index_hash_funcs

        self.signatures = [[0] * self.width for _ in range(self.stages)]
        self.values = [[0] * self.width for _ in range(self.stages)]
        self.ground_truth = defaultdict(int)

        self.key_width = key_width
        self.max_key = 2 ** key_width
        self.value_width = value_width
        self.max_value = 2 ** value_width
        self.signature_width = signature_width
        self.signature_mask = (2 ** signature_width) - 1

        self.keys_assigned = False

    def key_hash(self, key: int, stage: int):
        return self.index_hash_funcs[stage](key) % self.width

    def key_sig(self, key: int, stage: int):
        return self.signature_hash_funcs[stage](key) & self.signature_mask

    def add(self, key: int, value: int = 0) -> None:
        """
        Add a (key, value) pair to the list of items in the data structure.
        :param key: item key
        :param value: item value
        :return: None
        """
        assert(0 <= key < self.max_key)
        assert(0 <= value < self.max_value)

        self.ground_truth[key] = value

    SOURCE_NODE = "source"
    SINK_NODE = "sink"

    def key_node(self, key):
        """
        Get the name of the max-flow graph node for key `key`.
        :param key: The key
        :return: node name
        """
        return "key-%d" % key

    def cell_node(self, stage, cell_idx):
        """
        Get the name of the max-flow graph node for register cell in stage `stage` at index `cell_idx`.
        :param stage: stage in the data structure
        :param cell_idx: register cell index
        :return: node name
        """
        return "stage-%d-cell-%d" % (stage, cell_idx)

    def assign_keys(self):
        print("Computing")
        g = nx.DiGraph()

        stage_cell_sig_triples = defaultdict(list)
        for key in self.ground_truth:
            key_node = self.key_node(key)
            g.add_edge(self.SOURCE_NODE, key_node, capacity=1.0)
            for stage in range(self.stages):
                cell_idx = self.key_hash(key, stage)
                sig = self.key_sig(key, stage)
                stage_cell_sig_triples[(stage, cell_idx, sig)].append(key)

        for stage in range(self.stages):
            for cell_idx in range(self.width):
                cell_node = self.cell_node(stage, cell_idx)
                g.add_edge(cell_node, self.SINK_NODE, capacity=1.0)

        for (stage, cell_idx, sig), keys in stage_cell_sig_triples.items():
            if len(keys) > 1:
                continue  # don't consider collisions
            key_node = self.key_node(keys[0])
            cell_node = self.cell_node(stage, cell_idx)
            g.add_edge(key_node, cell_node, capacity=1.0)

        flow_value, flow_dict = nx.maximum_flow(g, self.SOURCE_NODE, self.SINK_NODE)

        success_rate = flow_value / len(self.ground_truth) * 100
        print("%d of %d keys (%.2f%%) were successfully inserted " % (flow_value, len(self.ground_truth), success_rate))

        stage_occupancies = [0] * self.stages
        for (stage, cell_idx, sig), keys in stage_cell_sig_triples.items():
            if len(keys) > 1:
                continue  # don't consider collisions
            key_node = self.key_node(keys[0])
            cell_node = self.cell_node(stage, cell_idx)
            if flow_dict[key_node][cell_node] > 0.0:
                if flow_dict[key_node][cell_node] < 1.0:
                    print("WARNING: max-flow solution is not integral!!")
                self.values[stage][cell_idx] = keys[0]
                stage_occupancies[stage] += 1

        print("Stage occupancies:", stage_occupancies)

        self.g = g
        self.keys_assigned = True


def rand32():
    """ For generating random salts """
    return random.randint(0, 0xffffffff)


NUM_UES = int(65536 * 3)


def struct_compute_test(num_ues=NUM_UES, stages=4, struct_width=65536, signature_width=2):
    print("%d UEs, %d stages, %d width, %d signature bits" % (num_ues, stages, struct_width, signature_width))

    index_hash_funcs = [make_crc16_func(polynomial=CRC16_DEFAULT_POLY + (0x100 * i), salt=0)
                        for i in range(stages)]
    sig_hash_funcs = [make_crc16_func(polynomial=CRC16_DEFAULT_POLY + 0x1010 + (0x101 * i), salt=0)
                      for i in range(stages)]

    thing = CompactHashThing(index_hash_funcs, sig_hash_funcs, width=struct_width, signature_width=signature_width)

    total_struct_size = struct_width * stages
    if num_ues > total_struct_size:
        print("What are you doing?")
        exit(1)
    print("If successful, occupancy will be %.2f%%" % (100 * num_ues / total_struct_size))

    for key in range(num_ues):
        thing.add(key)

    thing.assign_keys()


def main():
    # accuracy_test(num_ues=65536, num_mobile=60000)
    struct_compute_test()


if __name__ == "__main__":
    main()
