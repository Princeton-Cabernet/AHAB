#!/usr/bin/env python3
"AHAB project. © Robert MacDavid, Xiaoqi Chen, Princeton University. License: AGPLv3"

from __future__ import print_function
import time
import os, sys
from typing import List, Dict, Tuple, Union, Any
import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc


# Finding the correct threshold is shockingly error-prone, don't rewrite it
simulations_path = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../python/'))
sys.path.insert(1, simulations_path)
from estimators import correct_threshold


""" 
TODO: most-significant bits of vlink and vtrunk IDs should be physical pipeID.
These bits should be added after reading and discarded before writing, and we should only have enough
register cells per-pipe for the number of vlinks expected to be connected to a single pipe.
"""

def parse_int(integer: Union[str, int, bytes, float]) -> int:
    if type(integer) == str:
        if integer.startswith("0x"):
            return int(integer, base=16)
        elif integer.startswith("0b"):
            return int(integer, base=2)
        return int(integer, base=10)
    elif type(integer) in [bytes, bytearray]:
        return int.from_bytes(integer, "big")
    return int(integer)


class TernaryKey:
    value: int
    mask: int
    def __init__(self, key: Union[str, Tuple[int, int], Tuple[bytes, bytes]]):
        if type(key) is str:
            amp_count = key.count("&")
            if amp_count > 3 or amp_count < 1:
                raise Exception("Ternary keys should be provided as 'value&mask' or 'value&&&mask'")
            self.value, self.mask = key.split("&" * amp_count)
            self.value = parse_int(self.value)
            self.mask = parse_int(self.mask)
        elif type(key) is tuple:
            assert(len(key) == 2)
            self.value = parse_int(key[0])
            self.mask = parse_int(key[1])

    def __str__(self):
        return "{} &&& {}".format(self.value, self.mask)

    def doesnt_care(self) -> bool:
        return self.mask == 0

    def is_blank(self) -> bool:
        return self.mask == 0 and self.value == 0


import argparse
parser = argparse.ArgumentParser(description='Add mirror session to switch', 
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter)
parser.add_argument('-r', '--rate', type=float, default=1, help='Update period in seconds.')
parser.add_argument('-o', '--once', action='store_true',   help="Only perform one update. Otherwise, update indefinitely")
parser.add_argument('--verbose', '-v', action='count', default=0)
parser.add_argument('-f', '--fixed', type=int, default=0, required=False,
                    help="Fixed capacity which, if provided, will be installed instead of the max-min fairness capacity.")
parser.add_argument('-c', '--capacity', type=int, default=6450*10,
                    help="Default fixed capacity per VLink Group (AKA VTrunk), to be fairly shared within the group")
parser.add_argument('-C', '--clear', action='store_true',
                    help="If a match key is provided, this flag will determine if the table is cleared before installing the new rule")
parser.add_argument('-m', '--match', type=TernaryKey, default=TernaryKey("0&0"),
                    help="If installing a fixed capacity with -f, this ternary match key which vlink IDs will be matched")
parser.add_argument('-b', '--vlink-bits', type=int, default=10, required=False,
                    help = "Number of lower bits that correspond to the local vlink ID. Upper bits will be vtrunk ID")
parser.add_argument('-O', '--optimize-reads', type=str, default="", required=False,
                    help = "A string of comma-separated integers which, if provided, will be the only vlink rate register cell indices read. All others will be assumed zero.")
parser.add_argument('-s', '--smoothing', type=float, default=0.0, required=False,
                    help="Weight (in [0, 1)] to give prior slice capacities when updating, for smoothing out changes")
parser.add_argument('-g', '--growth-factor', type=float, default=1.2, required=False)
args=parser.parse_args()

assert(0 <= args.smoothing < 1)


# this should at most the size of each vlink resource in the p4 program (e.g. the number of rate trackers)
NUM_VLINKS = 4096
# log_2(slices per base-station)
VLINK_BITS = args.vlink_bits
if (1 << args.vlink_bits) > NUM_VLINKS:
    VLINK_BITS = (NUM_VLINKS-1).bit_length()
    print("WARNING: Vlink IDs only have %d bits. Reducing `--vlink-bits` to %d" % (VLINK_BITS, VLINK_BITS))
# slices per base station
VLINKS_PER_VTRUNK = 1 << VLINK_BITS
# log_2(base stations per upf)
NUM_VTRUNK_BITS = (NUM_VLINKS - 1).bit_length() - VLINK_BITS
# base stations per upf. Should be at most the size of vtrunk (aka vlink groups) resources in the p4 program
NUM_VTRUNKS = 1 << NUM_VTRUNK_BITS
# All (slice, base station) integer identifiers
ALL_VLINK_IDS = [_ for _ in range(NUM_VLINKS)]

VTRUNK_MASK = ((1 << (NUM_VTRUNKS.bit_length() - 1)) - 1) << VLINK_BITS

def print_nonzeroes(items):
    zeroes = 0
    parts = []
    for i, item in enumerate(items):
        if item != 0:
            parts.append("{}:{}".format(i,item))
        else:
            zeroes += 1
    print("{} zeroes. Nonzeros:".format(zeroes), end="")
    print("[{}]".format(",".join(parts)))



def vlink_id_to_vtrunk_id(vlink_id : int) -> int:
    return vlink_id >> VLINK_BITS


def vtrunk_id_to_vlink_ids(vtrunk_id : int) -> List[int]:
    vtrunk_bits = vtrunk_id << VLINK_BITS
    return [vtrunk_bits + i for i in range(VLINKS_PER_VTRUNK)]


def vtrunk_is_valid(vtrunk_id : int) -> bool:
    return 0 <= vtrunk_id < NUM_VTRUNKS


def vlink_is_valid(vlink_id : int) -> bool:
    return 0 <= vlink_id < NUM_VLINKS

def vtrunk_id_to_value_mask_match_pair(vtrunk_id : int) -> Tuple[int, int]:
    return (vtrunk_id << VLINK_BITS, VTRUNK_MASK)



# Connect to BF Runtime Server
interface = gc.ClientInterface(grpc_addr = "localhost:50052", client_id = 0, device_id = 0)
# Get the information about the running program on the bfrt server.
bfrt_info = interface.bfrt_info_get()
# Establish that you are working with this program
interface.bind_pipeline_config(bfrt_info.p4_name_get())
####### You can now use BFRT CLIENT #######
target = gc.Target(device_id=0, pipe_id=0xffff)


def make_key_list_for_read():
    demand_register = bfrt_info.table_dict["stored_vlink_demands"]
    register_data_name = list(demand_register.info.data_dict.keys())[0]
    return_key_list = list()
    return_data_list = list()
    vlink_ids_of_interest = ALL_VLINK_IDS
    if args.optimize_reads != "":
        vlink_ids_of_interest = [int(x) for x in args.optimize_reads.split(",")]
    for i in vlink_ids_of_interest:
        return_key_list.append(demand_register.make_key([gc.KeyTuple(u'$REGISTER_INDEX', i)]))
        return_data_list.append(demand_register.make_data([gc.DataTuple(register_data_name, 0)]))
    return return_key_list, return_data_list


key_list_for_read, data_list_for_clear = make_key_list_for_read()
demands_read = [0] * NUM_VLINKS


def clear_vlink_demands():
    global key_list_for_read
    global data_list_for_clear
    demand_register = bfrt_info.table_dict["stored_vlink_demands"]
    demand_register.entry_add(target, key_list_for_read, data_list_for_clear)
    if args.verbose > 0:
        print("Cleared {} demand register cells".format(len(key_list_for_read)))



_previous_read_demands = None
def smooth_demands(new_demands):
    global _previous_read_demands
    if args.smoothing == 0:
        return new_demands
    if _previous_read_demands is None:
        _previous_read_demands = new_demands
        return new_demands
    old_weight = args.smoothing
    new_weight = 1 - old_weight
    new_demands = [int((old_weight * old_demand) + (new_weight * new_demand))
            for old_demand, new_demand in zip(_previous_read_demands, new_demands)]
    _previous_read_demands = new_demands
    if args.verbose > 1:
        print("Read demands smoothed to ", end = "")
        print_nonzeroes(new_demands)
    return new_demands


def get_vlink_demands() -> List[int]:
    """ Scrape per-vlink demand registers 
    """
    global key_list_for_read
    global demands_read

    demand_register = bfrt_info.table_dict["stored_vlink_demands"]
    data_name = list(demand_register.info.data_dict.keys())[0]

    response = demand_register.entry_get(target, key_list_for_read, {"from_hw": True})
    clear_vlink_demands()
    count = 0
    for data, key in response:
        vlink_id = list(key.to_dict().values())[0]['value']
        values = data.to_dict()[data_name]
        demands_read[vlink_id] = max(values)
        count += 1
    if args.verbose == 1:
        print("Scraped {} of {} vlink demands.".format(count, NUM_VLINKS))
    elif args.verbose > 1:
        print("Scraped {} of {} vlink_demands: ".format(count, NUM_VLINKS), end=" ")
        print_nonzeroes(demands_read)
    demands_read = smooth_demands(demands_read)
    return demands_read


def compute_vtrunk_thresholds(vlink_demands: List[int], vtrunk_capacity: int ) -> List[int]:
    """ Given scraped vlink demands, compute the per-vtrunk threshold (aka per-vlink capacity)
    """
    vtrunk_thresholds = [0] * NUM_VTRUNKS
    trivial_count = 0
    for vtrunk_id in range(NUM_VTRUNKS):
        local_vlink_demands = [vlink_demands[vlink_id] for vlink_id in vtrunk_id_to_vlink_ids(vtrunk_id)]
        if args.verbose > 0:
            if (sum(local_vlink_demands) != 0):
                print("vtrunk {} local demands:".format(vtrunk_id), end="")
                print_nonzeroes(local_vlink_demands)
                print("max vtrunk bandwidth is {}. Current vtrunk usage is {}.".format(vtrunk_capacity, sum(local_vlink_demands)))
        computed_threshold = correct_threshold(local_vlink_demands, vtrunk_capacity, default_to_speculative=True, spec_factor=1.0)
        if computed_threshold == vtrunk_capacity:
            trivial_count += 1
        vtrunk_thresholds[vtrunk_id] = computed_threshold
    if args.verbose > 0:
        print("Computed {} vtrunk thresholds. {} were trivial".format(len(vtrunk_thresholds), trivial_count))
    if args.verbose > 1:
        print("Nontrivial thresholds: [{}]".format(
            ", ".join(["{}:{}".format(i,thresh) for i, thresh in enumerate(vtrunk_thresholds) if thresh != vtrunk_capacity])))
    return vtrunk_thresholds


def write_vtrunk_thresholds(vtrunk_thresholds : List[int], modify: bool) -> None:
    """ Write computed vtrunk thresholds to the data plane.
    """
    table = bfrt_info.table_dict["capacity_lookup"]

    key_list = list()
    data_list = list()
    for vtrunk_id, vtrunk_threshold in enumerate(vtrunk_thresholds):
        priority = 0  # arbitrary for now
        match_val, match_mask = vtrunk_id_to_value_mask_match_pair(vtrunk_id)
        key_list.append(table.make_key([gc.KeyTuple('$MATCH_PRIORITY', priority),
                                        gc.KeyTuple("eg_md.afd.vlink_id", match_val, match_mask)]))
        data_list.append(table.make_data([gc.DataTuple("vlink_capacity", vtrunk_threshold)],
                                          "load_vlink_capacity"))
    if modify:
        table.entry_mod(target, key_list, data_list)
    else:
        table.entry_add(target, key_list, data_list)
    if args.verbose == 0:
        print(". ", end="")
        sys.stdout.flush()
    else:
        print("Wrote {} vtrunk thresholds".format(len(key_list)))


def write_vtrunk_threshold_ternary(match_key: TernaryKey, threshold: int) -> None:
    """ Write a fixed vtrunk threshold to the dataplane for the given ternary match key.
    """
    table = bfrt_info.table_dict["capacity_lookup"]

    priority = 1  # arbitrary for now
    key = table.make_key([gc.KeyTuple('$MATCH_PRIORITY', priority),
                                    gc.KeyTuple("eg_md.afd.vlink_id", match_key.value, match_key.mask)])
    data = table.make_data([gc.DataTuple("vlink_capacity", threshold)],
                                      "load_vlink_capacity")
    try:
        table.entry_add(target, [key], [data])
        print("Wrote fixed capacity {} for vlink IDs matching {}.".format(threshold, match_key))
    except Exception as e:
        if "Already exists" in str(e.errors[0][1]):
            table.entry_mod(target, [key], [data])
            print("Changed capacity for vlink IDs matching {} to {}.".format(match_key, threshold))
        else:
            raise e


def clear_table(table_name: str):
    if args.verbose > 0:
        print("Clearing table {}".format(table_name))
    table = bfrt_info.table_dict[table_name]
    table.entry_del(target, [])




def main():
    if args.clear or args.match.is_blank():
        clear_table("capacity_lookup")

    if args.fixed > 0:
        if not args.match.is_blank():
            write_vtrunk_threshold_ternary(args.match, args.fixed)
            return
        print("Writing fixed vlink capacities")
        write_vtrunk_thresholds([args.fixed] * NUM_VTRUNKS, modify=False)
        print("Done writing fixed vlink capacities")
        return

    first_iter = True
    while True:
        vlink_demands = get_vlink_demands()
        vtrunk_thresholds = compute_vtrunk_thresholds(vlink_demands, args.capacity)
        write_vtrunk_thresholds(vtrunk_thresholds, modify=not first_iter)
        if args.once:
            break
        time.sleep(args.rate)
        first_iter = False


if __name__ == "__main__":
    main()

