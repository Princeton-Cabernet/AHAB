print("This script should be manually run on hardware testbed.")
from scapy.all import *
import time

iface='enp134s0f1'
tic=time.time(); sendp((Ether(dst='1:1:1:1:1:1',src='1:1:1:1:1:1')/IP())*1000, iface=iface); toc=time.time(); print(1000*(toc-tic),'ms')
