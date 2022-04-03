#!/usr/bin/env python3
from __future__ import print_function
import time
import sys
import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc

from typing import List, Tuple, Dict

import argparse
parser = argparse.ArgumentParser(description='Add mirror session to switch')
parser.add_argument('-p','--pipe', type=int, help='Pipe to scrape. -1 to scrape all.', default=-1)
parser.add_argument('-r','--rate', type=float, help='Scraping period in seconds.', default=0.1)
parser.add_argument('-i','--start-index', type=int, help='First index to scrape', default=36)
parser.add_argument('-j','--end-index', type=int, help='Last index to scrape', default=36)
parser.add_argument('-n','--register_name',type=str, help="Unique suffix of the name of the register to scrape", 
                        default="stored_thresholds")
args=parser.parse_args()


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

register_name = ""
table_names = bfrt_info.table_dict.keys()
for n in table_names:
    if str(n).endswith(args.register_name):
        register_name = n
        break
if register_name == "":
    print("No register with name matching '%s' was found!" % args.register_name)
    print("===========Available registers ==========")
    available_regs = []
    for n in table_names:
        t = bfrt_info.table_dict[n] 
        if u'$REGISTER_INDEX' in t.info.key_dict:
            available_regs.append(n)
    available_regs.sort()
    for i, n in enumerate(available_regs):
        print("%d: %s" % (i, n))
        
    print("===========End available registers ==========")
    sys.exit(1)
print("Found register with matching name:", register_name)

register = bfrt_info.table_dict[register_name]
data_name = list(register.info.data_dict.keys())[0]

while True:
    output_lines : List[str] = []
    output_str = ""
    output_lines.append("=============================")
    blank_entries = 0;
    key_list = list()
    for i in range(args.start_index, args.end_index):
        key_list.append(register.make_key([gc.KeyTuple(u'$REGISTER_INDEX', i)]))

    response = register.entry_get(target, key_list, {"from_hw": True})

    for data, key in response:
        index = list(key.to_dict().values())[0]['value']
        values_outer = data.to_dict()
        values = values_outer[data_name]
        if args.pipe == -1:
            if values.count(0) == len(values):
                blank_entries += 1
            else:
                output_lines.append("{} : {}".format(index, values))
        else:
            value = values[args.pipe]
            if value == 0:
                blank_entries += 1
            else:
                output_lines.append("{} : {}".format(index, value))
    output_lines.append("{} zero values read this round".format(blank_entries))
    output_lines.append("=============================")
    print('\n'.join(output_lines))
    time.sleep(args.rate)
