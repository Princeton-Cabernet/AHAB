#run scapy
# send some packets, sniff the reply

# note: the P4 program will clear mac src/dst addr to 0, which is used for separating replies from responses.

from scapy.all import *
import time
import sys

#shared functions across test scripts
from toolbox import *

def build_write_packet(id, thres):
    return Ether(
	src=int_to_mac(0),
	dst=int_to_mac(65536+1) #is_worker
    )/IP(
	src=int_to_ip(thres),
	dst=int_to_ip(thres),
        ttl=0,#vlink index
        id=10000+id,#IPID is used as testcase ID
    )/UDP()

def build_read_packet(id):
    return Ether(
            src=int_to_mac(0),
            dst=int_to_mac(65536+0)#not worker
    )/IP(
        id=id,#IPID is used as testcase ID
    )/UDP()

def build_input_packet(id,thres):
    return [build_write_packet(id,thres), build_read_packet(id)]

testcase_list=[
    {"thres":x}
    for x in [
        0, 50, 70
        ]+list(range(100,2000,50))+[5000,90000,1300000,290000000,  0]
]

testcase_input_map={
    idx:build_input_packet(id=idx,**case)
    for idx,case in enumerate(testcase_list)
}
testcase_ans_map={idx:None for idx,case in enumerate(testcase_list)}

def summarize_results():
    for idx,ans in testcase_ans_map.items():
        thres=testcase_list[idx]['thres']
        print(thres,' got',ans)

iface='veth0'
def sniff_thread(iface, num_wait,end_event):
    #when received >=num_wait responses, set end_event threading.Event
    received_counter={'x':0}
    print('start sniffing, expecting total output:',(num_wait))
    def proc_packet(p):
        #p.show2()
        if p['Ether'].dst==int_to_mac(0):
            #this is response
            id=p['IP'].id
            
            th_mid=mac_to_int(p['Ether'].src)
            th_lo=ip_to_int(p['IP'].src)
            th_hi=ip_to_int(p['IP'].dst)
            vlid=p['IP'].ttl
            cand_delta_pow=p['IP'].tos
            
            ret_parsed=(th_lo,th_mid,th_hi,vlid,cand_delta_pow)
            print('*** got response:',id, ret_parsed)
            testcase_ans_map[id]=ret_parsed
            received_counter['x']+=1
            if received_counter['x'] >= num_wait:
                print('that should be all')
                end_event.set()
                summarize_results()
                sys.exit(0)
        else:
            id=p['IP'].id
            print('Non-output packet:',id,p['Ether'].dst)
        return 
    sniff(iface=iface,prn=proc_packet)

_=sniff(iface=iface,timeout=1) #clear previous packets

wait_event=threading.Event()
t = threading.Thread(target=sniff_thread, args=(iface, len(testcase_list), wait_event))
t.start()
time.sleep(0.5)
#sendp all packet
for outp in testcase_input_map.values():
    sendp(outp, iface=iface)
wait_event.wait()
sys.exit(0)
