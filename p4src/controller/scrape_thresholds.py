#!/usr/bin/env python2
from __future__ import print_function

import sys
import time
import os
sys.path.append(os.path.expandvars('$SDE/install/lib/python2.7/site-packages/tofino/'))
import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc

import argparse
parser = argparse.ArgumentParser(description='Add mirror session to switch')
parser.add_argument('-p','--pipe', type=int, help='Pipe to scrape. -1 to scrape all.', default=-1)
parser.add_argument('-r','--rate', type=float, help='Scraping period in seconds.', default=1)
parser.add_argument('-i','--start-index', type=int, help='First index to scrape', default=0)
parser.add_argument('-j','--end-index', type=int, help='Last index to scrape', default=5)
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

register_name = u'SwitchIngress.vlink_lookup.stored_thresholds'
register_cell_name = register_name + u'.f1'

register = bfrt_info.table_dict[register_name]

while True:
    print("=============================")    
    blank_entries = 0;
    for i in range(args.start_index, args.end_index):
        key = register.make_key([gc.KeyTuple(u'$REGISTER_INDEX', i)])
        response = register.entry_get(target, [key], {"from_hw": True})

        for item in response:
            index = item[1].to_dict().values()[0]['value']
            values = item[0].to_dict()[register_cell_name]
            if args.pipe == -1:
                if values.count(0) == 4:
                    blank_entries += 1
                else:
                    print("%d : %s" % (index, str(values)))
            else:
                value = values[args.pipe]
                if value == 0:
                    blank_entries += 1
                else:
                    print("%d : %s" % (index, str(value)))
    print("%d zero values read this round" % blank_entries)
    print("=============================")    
    time.sleep(args.rate)
