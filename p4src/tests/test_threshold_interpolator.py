#run scapy
# send some packets, sniff the reply

# note: the P4 program will clear mac src/dst addr to 0, which is used for separating replies from responses.

from scapy.all import *
import time
import sys

#shared functions across test scripts
from toolbox import *

def build_input_packet(id,numerator,denominator,t_mid,delta_t_log,interp_op):
    assert(t_mid > 2**delta_t_log)
    assert(numerator <= denominator <= 2**32)
    assert(interp_op in [1,2])

    return Ether(
        src=int_to_mac(numerator),
        dst=int_to_mac(denominator)
    )/IP(
        id=id,#IPID is used as testcase ID
        src=int_to_ip(t_mid)
    )/UDP(
        sport=delta_t_log,
        dport=interp_op
    )


testcase_list=[
    {"numerator":i*100*1000,"denominator":1000*1000,"t_mid":5000,"delta_t_log":11,"interp_op":1}
    for i in range(10)
]+[
    {"numerator":i*100*1000,"denominator":1000*1000,"t_mid":5000,"delta_t_log":11,"interp_op":2}
    for i in range(10)
]

# a test case in the dead zone
#testcase_list = testcase_list[1:2]

rounding_precision = 5
for i, testcase_dict in enumerate(testcase_list):
    num = testcase_dict["numerator"]
    den = testcase_dict["denominator"]
    t_mid = testcase_dict["t_mid"]
    exp = testcase_dict["delta_t_log"]

    num_rounded = num
    den_rounded = den
    if den >= (1 << rounding_precision):
        num_rounded = num >> (den.bit_length() - rounding_precision)
        den_rounded = den >> (den.bit_length() - rounding_precision)

    perfect_result: int
    expected_result: int
    if testcase_dict["interp_op"] == 1:
        # interp_left
        perfect_result = round(t_mid - (num / den) * (2 ** exp))
        expected_result = round(t_mid - (num_rounded / den_rounded) * (2 ** exp))
    else:
        #interp_right
        perfect_result = round(t_mid + (num / den) * (2 ** exp))
        expected_result = round(t_mid + (num_rounded / den_rounded) * (2 ** exp))
    print("Test case:", i, ", Perfect answer:", perfect_result, ", LUT Answer:", expected_result)


testcase_input_map={
    idx:build_input_packet(id=idx,**case)
    for idx,case in enumerate(testcase_list)
}
testcase_ans_map={idx:None for idx,case in enumerate(testcase_list)}


iface='veth0'
def sniff_thread(iface, num_wait,end_event):
    #when received >=num_wait responses, set end_event threading.Event
    received_counter={'x':0}
    print('start sniffing, expecting total output:',(num_wait))
    def proc_packet(p):
        #p.show2()
        if p['Ether'].src==int_to_mac(0) and p['Ether'].dst==int_to_mac(0):
            #this is response
            id=p['IP'].id
            ret=p['IP'].dst
            ret_parsed=ip_to_int(ret)
            print('*** got response:',id,ret, ret_parsed)
            testcase_ans_map[id]=ret_parsed
            received_counter['x']+=1
            if received_counter['x'] >= num_wait:
                print('that should be all')
                end_event.set()
        return 
    sniff(iface=iface,prn=proc_packet)

_=sniff(iface=iface,timeout=1) #clear previous packets

wait_event=threading.Event()
t = threading.Thread(target=sniff_thread, args=(iface, len(testcase_list), wait_event))
t.start()
time.sleep(0.5)
#sendp all packet
sendp(list(testcase_input_map.values()), iface=iface)
wait_event.wait()
sys.exit(0)
