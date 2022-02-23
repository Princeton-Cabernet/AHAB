#!/usr/bin/env python3
from __future__ import print_function

import sys
import os

import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc

import argparse
parser = argparse.ArgumentParser(description='Add delta table rules via GRPC')
parser.add_argument('-i', '--low', type=int, default=10,
                    help='Log_2 of the lowest valid threshold, rounded down.')
parser.add_argument('-j', '--high', type=int, default=20,
                    help='Log_2 of the highest valid threshold, rounded down.')
parser.add_argument('-d', '--delta', type=int, default=1,
                    help="-Log_2 of the threshold delta's relative size. 1 corresponds to a delta of 1/2, 2 a delta of 1/4, etc.")
args=parser.parse_args()

if args.delta > args.low:
    print("ERROR: mangitude of param --delta should not exceed param --low")
    sys.exit(1)


# Connect to BF Runtime Server
interface = gc.ClientInterface(grpc_addr = "localhost:50052", client_id = 0, device_id = 0)
print('Connected to BF Runtime Server')

# Get the information about the running program on the bfrt server.
bfrt_info = interface.bfrt_info_get()
print('The target runs program ', bfrt_info.p4_name_get())

# Establish that you are working with this program
interface.bind_pipeline_config(bfrt_info.p4_name_get())

####### You can now use BFRT CLIENT #######
target = gc.Target(device_id=0, pipe_id=0xffff)

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
        pos_delta = (1 << delta_pow)
        neg_delta = -pos_delta
        pos_delta = 2 # DEBUG
        neg_delta = -2 # DEBUG
        if i == args.low:
            neg_delta=0
        if i == args.high:
            pos_delta=0;
        key_val = 1 << i
        delta_pow = 1 # DEBUG
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

