#!/usr/bin/env python3
from __future__ import print_function

import sys
import os
import argparse

import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc

from ipaddress import IPv4Network
from typing import Union, Tuple, Any, List, Dict

weight_options = {
        3:'rshift3',
        2:'rshift2',
        1:'rshift1',
        0:'noshift',
        -1:'lshift1',
        -2:'lshift2',
        -3:'lshift3'}
weight_to_action_name = {key : "set_vlink_{}".format(val) for key,val in weight_options.items()}
action_name_to_weight = {"set_vlink_{}".format(val):key for key,val in weight_options.items()}


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



parser = argparse.ArgumentParser(description='Add vlink lookup rules via GRPC',
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter)
parser.add_argument('-c', '--clear', action="store_true",
                    help= "Clear the vlink table before adding the new rule")
parser.add_argument('-C', '--clear-only', action="store_true",
                    help= "Clear the vlink table and don't add any rules")
parser.add_argument('-i', '--ip-dst', type=IPv4Network, required=True,
                    help="IPv4 prefix match, given in <address>/<prefix_len> format.")
parser.add_argument('-v', '--vlink', type=int, required=True,
                    help="VLink ID to assign to matching flows")
parser.add_argument('-w', '--weight', type=int, required=False, default=0, choices=weight_options.keys(),
                    help="log_2 of the weight to assign to matching flows. -1 is weight 1/2, 0 is weight 1, 1 is weight 2, etc")
parser.add_argument('-t', '--tcp-dport', type=TernaryKey, default=TernaryKey("0&0"), required=False,
                    help="TCP ternary dest port match, as the format value&&&mask. If provided, rule will only match TCP")
parser.add_argument('-u', '--udp-dport', type=TernaryKey, default=TernaryKey("0&0"), required=False,
                    help="UDP ternary dest port match, as the format value&&&mask. If provided, rule will only matc UDP")
parser.add_argument('-P', '--print', action="store_true",
                    help="Print table contents, don't add or delete any entries.")
args=parser.parse_args()

# Exactly one must be provided
if args.tcp_dport.is_blank() + args.udp_dport.is_blank() != 1:
    print("Either a TCP or a UDP port match must be provided, not both!")
    sys.exit(1)



# Connect to BF Runtime Server
interface = gc.ClientInterface(grpc_addr = "localhost:50052", client_id = 0, device_id = 0)
# Get the information about the running program on the bfrt server.
bfrt_info = interface.bfrt_info_get()
# Establish that you are working with this program
interface.bind_pipeline_config(bfrt_info.p4_name_get())
####### You can now use BFRT CLIENT #######
target = gc.Target(device_id=0, pipe_id=0xffff)

print("------------------------------")


# constants
table = bfrt_info.table_dict["tb_match_ip"]


ip_dst_addr_key_name = "dst_addr"
tcp_valid_key_name = "tcp_valid"
udp_valid_key_name = "udp_valid"
tcp_dport_key_name = "tcp_dport"
udp_dport_key_name = "udp_dport"
vlink_id_param_name = "i"


def weight_to_str(weight: int) -> str:
    weight_str = "1/1"
    if weight > 0:
        weight_str = "{}/1".format(1 << weight)
    elif weight < 0:
        weight_str = "1/{}".format(1 << -weight)
    return weight_str



def entry_to_str(ip_dst: IPv4Network, vlink_id: int,
        tcp_dport: TernaryKey, udp_dport: TernaryKey, 
        weight : int):
    l4_str = "TCP DPort = {}".format(tcp_dport) if not tcp_dport.is_blank() else "UDP DPort = {}".format(udp_dport)
    weight_str = weight_to_str(weight)
    return "Match[{}, {}] -> Assign(Vlink <- {}, Weight <- {})".format(
                ip_dst, l4_str, vlink_id, weight_str)


def print_table():
    key_list = list()
    # Read all entries
    response = table.entry_get(target, None, {"from_hw": True})
    print("----- Table entries -----")
    i = 0
    for data, key in response:
        ip_key = key.field_dict[ip_dst_addr_key_name]
        subnet = IPv4Network((parse_int(ip_key.value), parse_int(ip_key.prefix_len)))

        tcp_valid: bool = parse_int(key.field_dict[tcp_valid_key_name].value) > 0
        udp_valid: bool = parse_int(key.field_dict[udp_valid_key_name].value) > 0
        
        tcp_port_tmp = key.field_dict[tcp_dport_key_name]
        udp_port_tmp = key.field_dict[udp_dport_key_name]

        tcp_port = TernaryKey((tcp_port_tmp.value, tcp_port_tmp.mask))
        udp_port = TernaryKey((udp_port_tmp.value, udp_port_tmp.mask))

        vlink_id = data.to_dict()[vlink_id_param_name]

        weight = action_name_to_weight[data.action_name.split(".")[-1]]


        entry_str = entry_to_str(subnet, vlink_id, 
                                 tcp_port, udp_port, 
                                 weight)

        print("--", entry_str)

        i += 1
    print("%d entries total." % i)


def clear_table():
    print("Clearing VLink lookup table... ", end="")
    table.entry_del(target, None)
    print("done.")


def add_entry():
    tcp_valid: bool = not args.tcp_dport.is_blank()
    udp_valid: bool = not args.udp_dport.is_blank()
    key = table.make_key([gc.KeyTuple(ip_dst_addr_key_name, 
                                      value=parse_int(args.ip_dst.network_address.packed), 
                                      prefix_len=args.ip_dst.prefixlen), 
                          gc.KeyTuple(tcp_valid_key_name, tcp_valid),
                          gc.KeyTuple(udp_valid_key_name, udp_valid),
                          gc.KeyTuple(tcp_dport_key_name, 
                                      value=args.tcp_dport.value, 
                                      mask=args.tcp_dport.mask),
                          gc.KeyTuple(udp_dport_key_name, 
                                      value=args.udp_dport.value, 
                                      mask=args.udp_dport.mask)])
    #                      gc.KeyTuple(priority_key_name, args.priority)])
    action_name =  weight_to_action_name[args.weight]
    data = table.make_data([gc.DataTuple(vlink_id_param_name, args.vlink)], action_name)

    try:
        table.entry_add(target, [key], [data])
        entry_str = entry_to_str(args.ip_dst, args.vlink,
                                 args.tcp_dport, args.udp_dport,
                                 args.weight)
        print("Added entry: {}".format(entry_str)) 
    except gc.BfruntimeReadWriteRpcException as e:
        if "Already exists" in str(e.errors[0][1]):
            print("WARNING: Entry already exists")
        else:
            raise e


def main():
    if args.print:
        print_table()
        sys.exit(0)
    if args.clear or args.clear_only:
        clear_table()
    if not args.clear_only:
        add_entry()
        print_table()


if __name__ == "__main__":
    main()
