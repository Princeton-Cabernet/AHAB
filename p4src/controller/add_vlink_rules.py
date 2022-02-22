#!/usr/bin/env python3
from __future__ import print_function
import grpc
import ipaddress
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc

import argparse
parser = argparse.ArgumentParser(description='Add LPF rules via GRPC')
parser.add_argument('-m','--mode', type=str, choices=('RATE','SAMPLE'),help='LPF mode', default='RATE')
parser.add_argument('-d','--decay', type=float, help='Decay time constant', default=1e6)
parser.add_argument('-s','--scale', type=int, help='Scale down factor', default=1)
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

# First, enumerate all table names
table_names=bfrt_info.table_dict.keys()


#============ Begin edits ============#


vlink_lookup_table = bfrt_info.table_dict['SwitchIngress.vlink_lookup.tb_match_ip']
vlink_act_namef = "SwitchIngress.vlink_lookup.set_vlink_%sshift"
vtrunk_lookup_table = bfrt_info.table_dict['SwitchEgress.vtrunk_lookup']

def get_vlink_action_name(lshiftnum):
    if shiftnum == 0:
        return vlink_act_namef % "no"
    elif shiftnum > 0:
        return (vlink_act_namef % "l") + str(shiftnum)
    else:
        return (vlink_act_namef % "r") + str(-shiftnum)

def make_vlink_key(ipv4_prefix):
    prefix = ipaddress.ip_network(unicode(ipv4_prefix))
    
    return vlink_lookup_table.make_key([
            gc.KeyTuple('hdr.ipv4.dst_addr', str(prefix.network_address), prefix_len=prefix.prefixlen)])


def add_vlink_entry(vlink_id, ipv4_prefix, weight_pow):
    key = make_vlink_key(ipv4_prefix)

    data = vlink_lookup_table.make_data([gc.DataTuple('', vlink_id], get_vlink_action_name(weight_pow))

    vlink_lookup_table.entry_add(
        target, 
        [key], 
        [data]) 


#============ End edits ============#



relevant_table_names=[n for n in table_names if 'LPF' in n or 'lpf' in n]
relevant_tables=[]
for n in sorted(relevant_table_names):
    t=bfrt_info.table_dict[n]
    if t not in relevant_tables:
        relevant_tables.append(t)

def lpf_make_keytuple(i):
    return [gc.KeyTuple("$LPF_INDEX",value=i)]
def lpf_make_datatuple(rate_or_sample, time_const, scale_out):
    assert(rate_or_sample in ['RATE','SAMPLE'])
    dt1=gc.DataTuple("$LPF_SPEC_TYPE", str_val=rate_or_sample)
    dt2=gc.DataTuple("$LPF_SPEC_GAIN_TIME_CONSTANT_NS", float_val=time_const)
    dt3=gc.DataTuple("$LPF_SPEC_DECAY_TIME_CONSTANT_NS",float_val=time_const)
    dt4=gc.DataTuple("$LPF_SPEC_OUT_SCALE_DOWN_FACTOR",val=scale_out)
    return [dt1,dt2,dt3,dt4]

lpf_params=[args.mode, args.decay, args.scale] #TODO: use argparse
print("Using LPF parameters:",lpf_params)

for t in relevant_tables:
    print('Initializing table ',t.info.name,' size=',t.info.size)
    data=t.make_data( lpf_make_datatuple( *lpf_params ) )
    key_list=[]
    for i in range(t.info.size): 
        #todo: make it batch mode!
        key=t.make_key( lpf_make_keytuple(i) )
        key_list.append(key)
    data_list=[data]*len(key_list)
    t.entry_add(target, key_list=key_list, data_list=data_list)
        
print('Finished adding to all LPF tables.')
