#!/usr/bin/env python2
from __future__ import print_function

import sys
import os
sys.path.append(os.path.expandvars('$SDE/install/lib/python2.7/site-packages/tofino/'))
import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc

import argparse
parser = argparse.ArgumentParser(description='Add mirror session to switch')
parser.add_argument('-p','--port', type=int, help='Egress port the mirror session will clone to', default=68)
parser.add_argument('-s','--sid', type=int, help='Mirror session ID. Set this to the hardcoded one in afd.p4', default=50)
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

# get mirror session table
mirror_cfg_table = bfrt_info.table_get("$mirror.cfg")

####### mirror_cfg_table ########
# Define the key
key = mirror_cfg_table.make_key([gc.KeyTuple('$sid', args.sid)])
# Define the data for the matched key.
data = mirror_cfg_table.make_data([gc.DataTuple('$direction', str_val="INGRESS"),
                gc.DataTuple('$ucast_egress_port', args.port), gc.DataTuple('$ucast_egress_port_valid', bool_val=True),
                gc.DataTuple('$session_enable', bool_val=True)], '$normal')
# Add the entry to the table
mirror_cfg_table.entry_add(target, [key], [data])


print('Finished adding clone session %d for port %d' % (args.sid, args.port))
