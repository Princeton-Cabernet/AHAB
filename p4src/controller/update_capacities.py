#!/usr/bin/env python3
from __future__ import print_function
import time
import os, sys
from typing import List, Dict, Tuple
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

MAX_VTRUNK_BANDWIDTH = 6450 * 10  # 1GB
# base stations per UPF
NUM_VTRUNKS = 32
# log_2(slices per base-station)
VLINK_BITS = 4
# slices per base station
VLINKS_PER_VTRUNK = 2 ** VLINK_BITS
# number of vlinks across all base stations
NUM_VLINKS = NUM_VTRUNKS * VLINKS_PER_VTRUNK
# All (slice, base station) integer identifiers
ALL_VLINK_IDS = [_ for _ in range(NUM_VLINKS)]

VTRUNK_MASK = ((1 << (NUM_VTRUNKS.bit_length() - 1)) - 1) << VLINK_BITS


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


import argparse
parser = argparse.ArgumentParser(description='Add mirror session to switch')
parser.add_argument('-r', '--rate', type=float, default=1, help='Update period in seconds.')
parser.add_argument('-o', '--once', action='store_true',   help="Only perform one update. Otherwise, update indefinitely")
parser.add_argument('--verbose', '-v', action='count', default=0)
parser.add_argument('-f', '--fixed', type=int, default=0, 
                    help="Fixed capacity which, if provided, will be installed instead of the max-min fairness capacity.")
args=parser.parse_args()


# Connect to BF Runtime Server
interface = gc.ClientInterface(grpc_addr = "localhost:50052", client_id = 0, device_id = 0)
# Get the information about the running program on the bfrt server.
bfrt_info = interface.bfrt_info_get()
# Establish that you are working with this program
interface.bind_pipeline_config(bfrt_info.p4_name_get())
####### You can now use BFRT CLIENT #######
target = gc.Target(device_id=0, pipe_id=0xffff)


def get_vlink_demands() -> List[int]:
    """ Scrape per-vlink demand registers 
    """

    demand_register = bfrt_info.table_dict["stored_vlink_demands"]
    data_name = list(demand_register.info.data_dict.keys())[0]


    key_list = list()
    for i in ALL_VLINK_IDS:
        key_list.append(demand_register.make_key([gc.KeyTuple(u'$REGISTER_INDEX', i)]))

    demands_read = [0] * NUM_VLINKS
    response = demand_register.entry_get(target, key_list, {"from_hw": True})
    count = 0
    for data, key in response:
        vlink_id = list(key.to_dict().values())[0]['value']
        values = data.to_dict()[data_name]
        demands_read[vlink_id] = max(values)
        count += 1
    if args.verbose == 1:
        print("Scraped {} of {} vlink demands.".format(count, NUM_VLINKS))
    elif args.verbose > 1:
        nonzero_values = ["{}:{}".format(i, demand) for i, demand in enumerate(demands_read) if demand != 0]
        zero_count = count - len(nonzero_values)
        print("Scraped {} of {} vlink_demands. {} zero values. Nonzero values:".format(count, NUM_VLINKS, zero_count))
        print(', '.join(nonzero_values))
    return demands_read


def compute_vtrunk_thresholds(vlink_demands: List[int]) -> List[int]:
    """ Given scraped vlink demands, compute the per-vtrunk threshold (aka per-vlink capacity)
    """
    vtrunk_thresholds = [0] * NUM_VTRUNKS
    trivial_count = 0
    for vtrunk_id in range(NUM_VTRUNKS):
        local_vlink_demands = [vlink_demands[vlink_id] for vlink_id in vtrunk_id_to_vlink_ids(vtrunk_id)]
        computed_threshold = correct_threshold(local_vlink_demands, MAX_VTRUNK_BANDWIDTH)
        if computed_threshold == MAX_VTRUNK_BANDWIDTH:
            trivial_count += 1
        vtrunk_thresholds[vtrunk_id] = computed_threshold
    if args.verbose > 0:
        print("Computed {} vtrunk thresholds. {} were trivial".format(len(vtrunk_thresholds), trivial_count))
    if args.verbose > 1:
        print("Nontrivial thresholds: {}".format(
            ", ".join(["{}:{}".format(i,thresh) for i, thresh in enumerate(vtrunk_thresholds) if thresh != MAX_VTRUNK_BANDWIDTH])))
    return vtrunk_thresholds


def write_vtrunk_thresholds(vtrunk_thresholds : List[int], modify: bool) -> None:
    """ Write computed vtrunk thresholds to the data plane.
    """
    table = bfrt_info.table_dict["capacity_lookup"]

    key_list = list()
    data_list = list()
    for vtrunk_id, vtrunk_threshold in enumerate(vtrunk_thresholds):
        priority = 1  # arbitrary for now
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
    else:
        print("Wrote {} vtrunk thresholds".format(len(key_list)))

def clear_table(table_name: str):
    table = bfrt_info.table_dict[table_name]
    table.entry_del(target, [])


def main():
    clear_table("capacity_lookup")

    if args.fixed > 0:
        print("Writing fixed vlink capacities")
        write_vtrunk_thresholds([args.fixed] * NUM_VTRUNKS, modify=False)
        print("Done writing fixed vlink capacities")
        return

    first_iter = True
    while True:
        vlink_demands = get_vlink_demands()
        vtrunk_thresholds = compute_vtrunk_thresholds(vlink_demands)
        write_vtrunk_thresholds(vtrunk_thresholds, modify=not first_iter)
        if args.once:
            break
        time.sleep(args.rate)
        first_iter = False


if __name__ == "__main__":
    main()

