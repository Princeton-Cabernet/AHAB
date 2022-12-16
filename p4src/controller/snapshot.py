#!/usr/bin/env python3
"AHAB project. © Robert MacDavid, Xiaoqi Chen, Princeton University. License: AGPLv3"

from __future__ import print_function

import sys
import os
import time

import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc

from typing import List, Tuple, Union, Dict, Set
SnapshotCookie = Tuple[gc._Key, gc._Key, str, int, int]

import argparse
parser = argparse.ArgumentParser(description="Add and read tofino pipeline snapshots")
parser.add_argument('triggers', nargs='*', 
        help="Alternating sequence of trigger fields and their values. Default is an unconditional trigger")
parser.add_argument('-p', '--print', action='store_true', help="Print trigger field options")
parser.add_argument('-g', '--gress', type=str, choices=('ingress', 'egress'), default='ingress',
        help="Gress to use. Default = ingress")
parser.add_argument('-r', '--retries', type=int, default=-1, 
        help="Number of attempts to make when reading the snapshot contents. Default is limitless.")
parser.add_argument('-i', '--start-stage', type=int, default=0, help="First stage to capture")
parser.add_argument('-j', '--end-stage', type=int, default=11, help="Last stage to capture")
args = parser.parse_args()






# Connect to BF Runtime Server
interface = gc.ClientInterface(grpc_addr = "localhost:50052", client_id = 0, device_id = 0)
# Get the information about the running program on the bfrt server.
bfrt_info = interface.bfrt_info_get()
# Establish that you are working with this program
interface.bind_pipeline_config(bfrt_info.p4_name_get())
####### You can now use BFRT CLIENT #######
target = gc.Target(device_id=0, pipe_id=0xffff)

table_names = set(bfrt_info.table_dict.keys())

def get_live_stages(field_name: str, pipe: int, gress:str) -> Set[int]:
    snapshot_liveness_table = bfrt_info.table_get("snapshot.%s_liveness" % gress.lower())
    pipe_target = gc.Target(device_id=0, pipe_id=pipe)
    scope_resp = snapshot_liveness_table.entry_get(
            pipe_target,
            [snapshot_liveness_table.make_key([gc.KeyTuple('field_name', field_name)])])

    for data, key in scope_resp:
        data_dict = data.to_dict()
        return set(data_dict["valid_stages"])


def print_trig_field_options(gress: str):
    gress = gress.lower()
    assert gress in ["ingress", "egress"]
    table = bfrt_info.table_get("snapshot.%s_trigger" % gress)
    field_names = list(table.info.data_dict.keys())
    field_names.sort()
    for field_name in field_names:
        print(field_name)

def key_value_to_str(key_val: dict) -> str:
    if len(key_val) == 1:
        return list(key_val.values())[0]
    elif len(key_val) == 2 and 'value' in key_val and 'mask' in key_val:
        return "({} &&& {})".format(key_val['value'], key_val['mask'])
    return str(key_val)

def data_dict_to_param_str(data_dict: dict) -> str:
    return ", ".join("{}={}".format(k,v) for k,v in data_dict.items() if k not in set(["action_name", "is_default_entry"]))

def get_entry_str(table_name: str, handle: int) -> str:
    if table_name not in table_names:
        return "-\t{}[{}] ---> ? (hidden table)".format(table_name, handle)
    table = bfrt_info.table_get(table_name)
    if handle == 0:
        try:
            resp = table.default_entry_get(target)
            for data, key in resp:
                data_dict = data.to_dict()
                param_str = data_dict_to_param_str(data_dict)
                return "DEFAULT:     {}[]\n\t\t---> {}({})".format(table_name, data_dict['action_name'], param_str)
        except:
            return "{} -> ERROR reading default entry with handle {}".format(table_name, handle)
    else:
        resp = table.entry_get(target, handle=handle, flags={"from_hw":True})
        for data, key in resp:
            key_dict = key.to_dict()
            data_dict = data.to_dict()
            #print("KEY DICT", key_dict)
            #print("DATA DICT", data_dict)
            action_name = data_dict['action_name']
            key_str = ", ".join("{}={}".format(key_name, key_value_to_str(key_value)) for key_name, key_value in key_dict.items())
            key_str = "{}".format(key_str)
            param_str = data_dict_to_param_str(data_dict)
            return "HIT:         {}[{}]\n\t\t---> {}({})".format(table_name, key_str, action_name, param_str)
        return ""


def clear_snapshot_program():
    snapshot_table_names = ["snapshot.ingress_trigger", "snapshot.egress_trigger", "snapshot.cfg"]
    for table_name in snapshot_table_names:
        table = bfrt_info.table_get(table_name)
        table.entry_del(target, [])


def to_trig_field(field_name: str, gress: str) -> str:
    gress = gress.lower()
    assert gress in ["ingress", "egress"]
    table = bfrt_info.table_get("snapshot.%s_trigger" % gress)
    found_names = []
    for full_field_name in table.info.data_dict.keys():
        if full_field_name.endswith(field_name):
            found_names.append(full_field_name)
    if len(found_names) == 1:
        return found_names[0]
    elif len(found_names) > 1:
        raise Exception("Field name %s is ambiguous. Found matching fields: %s" % (field_name, str(found_names)))
    else:
        raise Exception("Field name not found in %s: %s" % (gress, field_name))


def make_trigger_fields(fields: List[Tuple[str, Union[int, bool, str]]], 
        gress: str) -> List[gc.DataTuple]:
    return [gc.DataTuple(to_trig_field(field_name, gress=gress), field_value)
                    for field_name, field_value in fields]


def make_unconditional_trigger_fields(gress: str) -> List[gc.DataTuple]:
    arbitrary_validity: str = None
    table = bfrt_info.table_get("snapshot.%s_trigger" % gress)
    for name in table.info.data_dict.keys():
        if name.endswith("$valid"):
            arbitrary_validity = name
            break
    arbitrary_validity_mask = arbitrary_validity + "_mask"
    return [gc.DataTuple(arbitrary_validity, 1),
            gc.DataTuple(arbitrary_validity_mask, 0)]


def add_snapshot_trigger(start_stage: int, end_stage: int, gress: str,
        trigger_fields: List[gc.DataTuple] = None)  -> SnapshotCookie:
    snapshot_liveness_table = bfrt_info.table_get("snapshot.%s_liveness" % gress.lower())
    snapshot_cfg_table = bfrt_info.table_get("snapshot.cfg")
    snapshot_trig_table = bfrt_info.table_get("snapshot.%s_trigger" % gress.lower())
    snapshot_data_table = bfrt_info.table_get("snapshot.%s_data" % gress.lower())
    snapshot_phv_table = bfrt_info.table_get("snapshot.phv")

    gress = gress.upper()
    assert gress in ["INGRESS", "EGRESS"]

    if trigger_fields is None:
        trigger_fields = make_unconditional_trigger_fields()

    snapshot_cfg_key = snapshot_cfg_table.make_key([
        gc.KeyTuple('start_stage', start_stage),
        gc.KeyTuple('end_stage', end_stage)])

    print(snapshot_cfg_table.info.data_dict.keys())
    print([n for n in table_names if 'snapshot' in n])
    """
    snapshot_cfg_data = snapshot_cfg_table.make_data([
        gc.DataTuple('thread', str_val=gress.upper()),
        gc.DataTuple('timer_enable', bool_val=False),
        gc.DataTuple('timer_value_usecs', val=0xff),
        gc.DataTuple('{}_trigger_mode'.format(gress.lower()), str_val=gress.upper())])
    """
    snapshot_cfg_data = snapshot_cfg_table.make_data([gc.DataTuple('thread', str_val=gress.upper())])
    snapshot_cfg_table.entry_add(
        target,
        [snapshot_cfg_key],
        [snapshot_cfg_data])

    snapshot_trig_key = snapshot_trig_table.make_key([
        gc.KeyTuple('stage', start_stage)])

    
    trigger_fields = [gc.DataTuple('enable', bool_val=True)] + trigger_fields
    snapshot_trig_data = snapshot_trig_table.make_data(trigger_fields)

    snapshot_trig_table.entry_add(
        target,
        [snapshot_trig_key],
        [snapshot_trig_data])

    return (snapshot_cfg_key, snapshot_trig_key, gress, start_stage, end_stage)


def read_snapshot(snapshot_cookie: SnapshotCookie) -> bool:
    snapshot_cfg_key, snapshot_trig_key, gress, start_stage, end_stage = snapshot_cookie

    snapshot_liveness_table = bfrt_info.table_get("snapshot.%s_liveness" % gress.lower())
    snapshot_cfg_table = bfrt_info.table_get("snapshot.cfg")
    snapshot_trig_table = bfrt_info.table_get("snapshot.%s_trigger" % gress.lower())
    snapshot_data_table = bfrt_info.table_get("snapshot.%s_data" % gress.lower())
    snapshot_phv_table = bfrt_info.table_get("snapshot.phv")
    

    pipe_triggered = -1
    for data, key in snapshot_trig_table.entry_get(target, [snapshot_trig_key]):
        assert key == snapshot_trig_key
        for i, state in enumerate(data.to_dict()['trigger_state']):
            if state == "FULL":
                pipe_triggered = i
    if pipe_triggered == -1:
        print("Snapshot not triggered")
        return False

    one_pipe_target = gc.Target(device_id=0, pipe_id=pipe_triggered)

    no_table: bool = False
    previous_fields: dict = {}
    print("")
    print("")
    print("===============================================================================================")
    print("|||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||")
    print("===============================================================================================")
    print("")
    print("")
    liveness_map: Dict[str, Set[int]] = {}
    for stage in range(start_stage, end_stage + 1):
        snapshot_data_key = snapshot_data_table.make_key([
                gc.KeyTuple('stage', stage)])

        resp = snapshot_data_table.entry_get(one_pipe_target, [snapshot_data_key])

        # Iterate over the response data
        delim = "-" * 16
        print("================== Stage %d ==================" % stage)
        for data, key in resp:
            assert key == snapshot_data_key
            data_dict = data.to_dict()
            no_table = data_dict['table_info'][0]['table_name'] == "NO_TABLE"
            print("{} Field Info {}".format(delim, delim))
            fields_sorted = [(key,val) for key,val in data_dict.items() 
                    if key not in set(["table_info", "action_name", 
                                   "is_default_entry", "local_stage_trigger", 
                                   "prev_stage_trigger", "timer_trigger", "next_table_name"])]
            fields_sorted.sort(key = lambda x : x[0])
            for field, val in fields_sorted:
                if field not in liveness_map:
                    liveness_map[field] = get_live_stages(field, pipe_triggered, gress)
                change_str = ''
                liveness_str = '' if stage in liveness_map[field] else ' (Unalive)'
                if field in previous_fields:
                    previous_val = previous_fields[field]
                    if val != previous_val:
                        change_str = '  (was {})'.format(previous_val)
                print("{:<30} = {:>10}{}{}".format(field, val, change_str, liveness_str))
            previous_fields = data_dict
            if no_table:
                break
            print("{} Control Info {}".format(delim, delim))
            if no_table:
                print("No tables this stage!")
            else:
                print("{} tables present this stage".format(len(data_dict['table_info'])))
            hit_tables = []
            unexecuted_tables = []
            for table_desc in data_dict['table_info']:
                table_name = table_desc['table_name']
                # discard first two namespaces of the table name ("pipe.gress")
                #table_name = table_name[table_name.find('.',table_name.find('.')+1)+1:]
                table_name = table_name.lstrip("pipe.")
                control_str = "(hit={}, inhib={}, exec={})".format(
                        table_desc['table_hit'],
                        table_desc['table_inhibited'],
                        table_desc['table_executed'])
                #print(table_desc)
                if table_desc['table_inhibited'] == 0 and table_desc['table_executed'] == 1:
                    hit_handle = table_desc['match_hit_handle']
                    hit_str = get_entry_str(table_name, hit_handle)
                    hit_tables.append(hit_str) 
                else:
                    unexecuted_tables.append((table_name, control_str))
            hit_tables.sort(key = lambda x : x[0])
            unexecuted_tables.sort(key = lambda x: x[0])
            print("-- Executed Tables --")
            for hit in hit_tables:
                print(hit)
            print("-- Non-executed Tables --")
            for name, control_str in unexecuted_tables:
                print('-\t', name, ":", control_str)
            print("{} Next Table = {}".format(delim, data_dict["next_table_name"]))
        print("=============================================")
        print("")
        if no_table:
            break
    print("")
    print("")
    return True


def read_snapshot_until_success(snapshot_cookie: SnapshotCookie, retries=-1, sleep_time=1.0): 
    attempt = 0
    while attempt != retries:
        attempt += 1
        if read_snapshot(snapshot_cookie):
            return
        print("Snapshot empty after %d retries" % attempt) 
        time.sleep(sleep_time)
    print("Failed to read snapshot after {} tries".format(retries))


def main():
    if args.print:
        print_trig_field_options(args.gress)
        return

    
    triggers = args.triggers
    print(triggers)
    if len(triggers) == 0:
        triggers = make_unconditional_trigger_fields(gress=args.gress)
    else:
        trigger_fields = []
        trigger_values = []
        i = 0
        for var in triggers:
            if i == 0:
                i = 1
                trigger_fields.append(var)
            elif i == 1:
                i = 0
                value: int
                if var.startswith('0x'):
                    value = int(var, base=10)
                elif var.startswith('0b'):
                    value = int(var, base=2)
                else:
                    value = int(var)
                trigger_values.append(value)
        triggers = make_trigger_fields(zip(trigger_fields, trigger_values), gress=args.gress)


    clear_snapshot_program()
    cookie = add_snapshot_trigger(start_stage=args.start_stage, 
                                  end_stage=args.end_stage, 
                                  gress=args.gress,
                                  trigger_fields=triggers)
    read_snapshot_until_success(cookie)
    clear_snapshot_program()


if __name__ == "__main__":
    main()
