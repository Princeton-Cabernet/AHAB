#!/usr/bin/env python3
from __future__ import print_function

import sys
import os
import time

import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as gc

from typing import List, Tuple, Union, Dict
SnapshotCookie = Tuple[gc._Key, gc._Key, str, int, int]


# Connect to BF Runtime Server
interface = gc.ClientInterface(grpc_addr = "localhost:50052", client_id = 0, device_id = 0)
# Get the information about the running program on the bfrt server.
bfrt_info = interface.bfrt_info_get()
# Establish that you are working with this program
interface.bind_pipeline_config(bfrt_info.p4_name_get())
####### You can now use BFRT CLIENT #######
target = gc.Target(device_id=0, pipe_id=0xffff)



def clear_snapshot_program():
    snapshot_table_names = ["snapshot.ingress_trigger", "snapshot.cfg"]
    for table_name in snapshot_table_names:
        table = bfrt_info.table_get(table_name)
        table.entry_del(target, [])


def to_trig_field(field_name: str, gress: str = "ingress") -> str:
    gress = gress.lower()
    assert gress in ["ingress", "egress"]
    table = bfrt_info.table_get("snapshot.%s_trigger" % gress)
    found_names = []
    for full_field_name in table.info.data_dict.keys():
        if full_field_name.endswith(field_name):
            found_names.append(full_field_name)
    print("{} mapped to {}".format(field_name, found_names))
    if len(found_names) == 1:
        return full_field_name
    elif len(found_names) > 1:
        raise Exception("Field name %s is ambiguous. Found matching fields: %s" % (field_name, str(found_names)))
    else:
        raise Exception("Field name not found in %s: %s" % (gress, field_name))


def make_trigger_fields(fields: List[Tuple[str, Union[int, bool, str]]], 
        gress: str = "ingress") -> List[gc.DataTuple]:
    return [gc.DataTuple(to_trig_field(field_name, gress=gress), field_value) 
                    for field_name, field_value in fields]


def make_unconditional_trigger_fields(gress: str = "ingress") -> List[gc.DataTuple]:
    arbitrary_validity: str = None
    table = bfrt_info.table_get("snapshot.%s_trigger" % gress)
    for name in table.info.data_dict.keys():
        if name.endswith("$valid"):
            arbitrary_validity = name
            break
    arbitrary_validity_mask = arbitrary_validity + "_mask"
    return [gc.DataTuple(arbitrary_validity, 1),
            gc.DataTuple(arbitrary_validity_mask, 0)]


def add_snapshot_trigger(start_stage: int, end_stage: int,
        trigger_fields: List[gc.DataTuple] = None, 
        gress: str = "ingress") -> SnapshotCookie:
    snapshot_liveness_table = bfrt_info.table_get("snapshot.%s_liveness" % gress.lower())
    snapshot_cfg_table = bfrt_info.table_get("snapshot.cfg")
    snapshot_trig_table = bfrt_info.table_get("snapshot.%s_trigger" % gress.lower())
    snapshot_data_table = bfrt_info.table_get("snapshot.%s_data" % gress.lower())
    snapshot_phv_table = bfrt_info.table_get("snapshot.phv")

    gress = gress.upper()
    assert gress in ["INGRESS", "EGRESS"]

    if trigger_fields is None:
        trigger_fields = make_unconditional_trigger_fields()
    print("FFFFF", [field.name for field in trigger_fields])

    snapshot_cfg_key = snapshot_cfg_table.make_key([
        gc.KeyTuple('start_stage', start_stage),
        gc.KeyTuple('end_stage', end_stage)])

    snapshot_cfg_data = snapshot_cfg_table.make_data([
        gc.DataTuple('thread', str_val=gress.upper()),
        gc.DataTuple('timer_enable', bool_val=False),
        gc.DataTuple('timer_value_usecs', val=0xff),
        gc.DataTuple('ingress_trigger_mode', str_val=gress.upper())])

    snapshot_cfg_table.entry_add(
        target,
        [snapshot_cfg_key],
        [snapshot_cfg_data])

    snapshot_trig_key = snapshot_trig_table.make_key([
        gc.KeyTuple('stage', start_stage)])

    
    trigger_fields = [gc.DataTuple('enable', bool_val=True)] + trigger_fields
    print([field.name for field in trigger_fields])
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
    for stage in range(start_stage, end_stage + 1):
        snapshot_data_key = snapshot_data_table.make_key([
                gc.KeyTuple('stage', stage)])

        resp = snapshot_data_table.entry_get(one_pipe_target, [snapshot_data_key])

        # Iterate over the response data
        print("================== Stage %d ==================" % stage)
        for data, key in resp:
            assert key == snapshot_data_key
            data_dict = data.to_dict()
            no_table = data_dict['table_info'][0]['table_name'] == "NO_TABLE"
            if no_table:
                print("No tables this stage!")
            else:
                print("{} tables present this stage".format(len(data_dict['table_info'])))
            print("----- Field Info -----")
            fields_sorted = [(key,val) for key,val in data_dict.items() 
                    if key not in set(["table_info", "action_name", 
                                   "is_default_entry", "local_stage_trigger", 
                                   "prev_stage_trigger", "timer_trigger", "next_table_name"])]
            fields_sorted.sort(key = lambda x : x[0])
            for field, val in fields_sorted:
                change_str = ''
                if field in previous_fields:
                    previous_val = previous_fields[field]
                    if val != previous_val:
                        change_str = '  (was {})'.format(previous_val)
                print("{:<30} = {:>10}{}".format(field, val, change_str))
            previous_fields = data_dict
            if no_table:
                break
            print("----- Control Info -----")
            for table_desc in data_dict['table_info']:
                print("-- Table {} --".format(table_desc['table_name']))
                for key, val in table_desc.items():
                    if key == 'table_name': continue
                    print("{:<30} = {:>10}".format(key, val))

            print("Next Table = {}".format(data_dict["next_table_name"]))
        print("=============================================")
        if no_table:
            break
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
    clear_snapshot_program()
    trigger_fields = make_trigger_fields([
        ('ethernet.$valid', 1),
        ('ethernet.$valid_mask', 0)])
    cookie = add_snapshot_trigger(start_stage=0, end_stage=5)
    read_snapshot_until_success(cookie)


if __name__ == "__main__":
    main()
