print("This script should be manually run on hardware testbed.")
from scapy.all import *
import time

stat={True:0,False:0}
def am_i_worker(p):
    if p['Ether'].dst!='00:00:00:00:00:00': return #outgoing
    tf=p['Ether'].src!='00:00:00:00:00:00'
    stat[tf]+=1
    print(stat,' worker percentage:', stat[True]/(stat[True]+stat[False]))
sniff(iface=iface, prn=am_i_worker)

