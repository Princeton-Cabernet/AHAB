#run scapy
# send some packets, sniff the reply

# note: the P4 program will clear mac dst addr to 0, which is used for separating replies from responses.

from scapy.all import *
import time
import sys

#shared functions across test scripts
from toolbox import *


def build_input_packet(id, measured_rate, t_lo,t_mid,t_hi):
    assert(t_lo <= t_mid <= t_hi)
    assert(t_mid!=0)
    return Ether(
        src=int_to_mac(measured_rate),
        dst=int_to_mac(t_mid)
    )/IP(
        id=id,#IPID is used as testcase ID
        src=int_to_ip(t_lo),
        dst=int_to_ip(t_hi)
    )/UDP(
        sport=123,
        dport=321
    )


REPEAT=20
testcase_list=[
        {"measured_rate":int(i*0.1*base),"t_lo":int(0.7*base),"t_mid":int(base),"t_hi":int(1.3*base)}
        for i in [0,1,4,8]+list(range(10,20))+[25,30,40,60,80,120,160,320,640]
        for base in [1000,10000,1000000]
]*REPEAT  #each repeat 10 times

# a test case in the dead zone
#testcase_list = testcase_list[1:2]

testcase_input_map={
    idx:build_input_packet(id=idx,**case)
    for idx,case in enumerate(testcase_list)
}
testcase_ans_map={idx:None for idx,case in enumerate(testcase_list)}


iface='veth0'

def parse_resp(mac_addr):
    arr=str(mac_addr).split(':')
    assert(arr[0]=='00')
    assert(arr[2]=='00')
    assert(arr[4]=='00')
    return int(arr[1]),int(arr[3]),int(arr[5])


def summarize_results():
    result_lists={}
    for i in sorted(testcase_ans_map.keys()):
        if testcase_ans_map[i]==None: continue
        case=testcase_list[i]
        base, meas = case['t_mid'],case['measured_rate']    
        if (base,meas) not in result_lists:
            result_lists[(base,meas)]=[]
        result_lists[(base,meas)].append( testcase_ans_map[i] )

    allpairs=result_lists.keys()
    allbase=sorted(set([b for b,m in allpairs]))
    for base in allbase:
        allmeas=sorted([m for b,m in allpairs if b==base])
        print('**** base=',base)
        for meas in allmeas:
            l_tup=sorted(result_lists[(base,meas)]) 
            v_lo =[x[0] for x in l_tup]
            v_mid=[x[1] for x in l_tup]
            v_hi =[x[2] for x in l_tup]

            def printvect(v):
                return ''.join([' ' if x==0 else '*' for x in v])
            ratio=meas/base
            infoline=(f'base={base} measured={meas} ratio={ratio}')
            ansline='\t lo:['+printvect(v_lo)+'] \t mid:['+printvect(v_mid)+'] \t hi:['+printvect(v_hi)+']'
            print(ansline +'\t\t'+ infoline)


def sniff_thread(iface, num_wait,end_event):
    #when received >=num_wait responses, set end_event threading.Event
    received_counter={'x':0}
    print('start sniffing, expecting total output:',(num_wait))
    def proc_packet(p):
        #p.show2()
        if p['Ether'].dst==int_to_mac(0):
            #this is response
            id=p['IP'].id
            resp=p['Ether'].src
            ret_parsed=parse_resp(resp)
            r=received_counter['x']
            print('*** got response: id=',id, f'{r}/{num_wait}',ret_parsed)
            testcase_ans_map[id]=ret_parsed
            received_counter['x']+=1
            if received_counter['x'] >= num_wait:
                print('that should be all')
                summarize_results()
                end_event.set()
                sys.exit(0)
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
