#run scapy
# send some packets, sniff the reply

# note: the P4 program will clear mac dst addr to 0, which is used for separating replies from responses.

from scapy.all import *

def int_to_mac(i):
    #start from lower
    def to_two_hex(num):
        assert(0<=num<=255)
        return hex(256+num)[-2:]
    ret=[]
    for _ in range(6):
        remainder=i%256
        ret.append(to_two_hex(remainder))
        i=i//256
    return ':'.join(reversed(ret))

def int_to_ip(i):
    ret=[]
    for _ in range(4):
        remainder=i%256
        ret.append(str(remainder))
        i=i//256
    return '.'.join(reversed(ret))

def ip_to_int(ip):
    numarr=[int(x) for x in ip.split('.')]
    ret=0
    for i in numarr:
        ret*=256
        ret+=i
    return ret

def mac_to_int(mac):
    for s in mac.split(":"): assert(len(s)==2)
    return int('0x'+mac.replace(':',''),16)
