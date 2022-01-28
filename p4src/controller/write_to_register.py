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
parser.add_argument('-v','--value',type=int, help="Value to write to the register cells.", default=0) 
parser.add_argument('-p','--pipe', type=int, help='Pipe to write to. -1 to write to all.', default=-1)
parser.add_argument('-i','--start-index', type=int, help='First index to write', default=0)
parser.add_argument('-j','--end-index', type=int, help='Last index to write', default=5)
parser.add_argument('-n','--register_name',type=str, help="Unique suffix of the name of the register to write", 
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
pipe_id = 0xffff
if args.pipe != -1:
    pipe_id = args.pipe
target = gc.Target(device_id=0, pipe_id=pipe_id)

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
print("Register", register)

print("Getting data name")
register_data_name = register.info.data_dict.keys()[0]
print('Register data name', register_data_name)
print("Getting data")
data = register.make_data([gc.DataTuple(register_data_name, int(args.value))])

cells_written = 0
for i in range(args.start_index, args.end_index):
    key = register.make_key([gc.KeyTuple(u'$REGISTER_INDEX', i)])
    register.entry_add(target, [key], [data])
    cells_written =+ 1
print("Done writing value '%d' to %d cells" % (args.value, cells_written))

