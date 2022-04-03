#!/usr/bin/env python3
from __future__ import print_function

import sys
import os

import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc
from ipaddress import IPv4Network

weight_options = {
        '3':'rshift3',
        '2':'rshift2',
        '1':'rshift1',
        '0':'noshift',
        '-1':'lshift1',
        '-2':'lshift2',
        '-3':'lshift3'}

def str_to_int(int_str: str):
    if int_str.startswith("0x"):
        return int(int_str, base=16)
    elif int_str.startswith("0b"):
        return int(int_str, base=2)
    return int(int_str, base=10)

class TernaryKey:
    value: int
    mask: int
    def __init__(self, key_str: str):
        amp_count = key_str.count("&")
        if amp_count > 3 or amp_count < 1:
            raise Exception("Ternary keys should be provided as 'value&mask' or 'value&&&mask'")
        self.value, self.mask = key_str.split("&" * amp_count)
        self.value = str_to_int(self.value)
        self.mask = str_to_int(self.mask)

    def __str__(self):
        return "{}&&&{}".format(self.value, self.mask)



import argparse
parser = argparse.ArgumentParser(description='Add vlink lookup rules via GRPC')
parser.add_argument('-i', '--ip', type=IPv4Network, required=True)
parser.add_argument('-s', '--dst-port', type=TernaryKey, default=TernaryKey("0&0"), required=False,
                    help="Ternary source port match, as the format value&&&mask")
parser.add_argument('-d', '--dst-port', type=TernaryKey, default=TernaryKey("0&0"), required=False)
                    help="Ternary destination port match, as the format value&&&mask")
parser.add_argument('-t', '--tcp', action="store_true", help="Matches on TCP if this flag is provided, else UDP")
args=parser.parse_args()


# Connect to BF Runtime Server
interface = gc.ClientInterface(grpc_addr = "localhost:50052", client_id = 0, device_id = 0)
# Get the information about the running program on the bfrt server.
bfrt_info = interface.bfrt_info_get()
# Establish that you are working with this program
interface.bind_pipeline_config(bfrt_info.p4_name_get())
####### You can now use BFRT CLIENT #######
target = gc.Target(device_id=0, pipe_id=0xffff)

vlink_table_name = "tb_match_ip"
action_namef = "set_vlink_{}"


# First, enumerate all table names
table_names=bfrt_info.table_dict.keys()

# constants
action_name = "compute_candidates_act"
key_name = "afd_md.threshold"
param_names = ["candidate_delta", "candidate_delta_negative", "candidate_delta_pow"]

# find our table
table_name = [n for n in table_names if "compute_candidates" in n][0]
table = bfrt_info.table_dict[table_name]


def clear_table():
    print("Clearing table %s" % table_name)
    key_list = list()
    # Read all entries
    response = table.entry_get(target, None, {"from_hw": True})
    for data, key in response:
        key_list.append(key)
    # Delete all read entries
    table.entry_del(target, key_list)
    print("Cleared %d entries from table %s" % (len(key_list), table_name))


def add_entries():
    key_list = list()
    data_list = list()
    str_list = list()
    for i in range(args.low, args.high+1):
        delta_pow = i - args.delta
        if args.delta_abs >= 0:
            delta_pow = args.delta_abs
        pos_delta = (1 << delta_pow)
        neg_delta = -pos_delta
        if i == args.low:
            neg_delta=0
        if i == args.high:
            pos_delta=0;
        key_val = 1 << i
        key_mask = (0xffffffff << i) & 0xffffffff
        action_params = (pos_delta, neg_delta, i-1)

        priority = i  # Defensive. Priority shouldn't matter because entries shouldn't intersect.

        key_list.append(table.make_key([gc.KeyTuple('$MATCH_PRIORITY', priority),
                                        gc.KeyTuple(key_name, key_val, key_mask)]))

        data_list.append(table.make_data([gc.DataTuple(param_names[0], pos_delta),
                                          gc.DataTuple(param_names[1], neg_delta),
                                          gc.DataTuple(param_names[2], delta_pow)],
                                          action_name))

        # For printing
        key_str = "0x%x &&& 0x%x" % (key_val, key_mask)
        act_str = "compute_candidates_act(%d, %d, %d)" % action_params
        entry_str = "(%s): %s;" % (key_str, act_str)    
        str_list.append(entry_str)

    table.entry_add(target, key_list, data_list)
    print("Added entries:")
    for entry_str in str_list:
        print(entry_str)


clear_table()
add_entries()

