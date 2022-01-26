# Not completed, manually tested


def newp(drop_lo,drop_mid,drop_hi,slice='00'):
        return Ether(
            src=slice+':0:0:0:0:0',
            dst='1:1:1:1:1:1'
            )/IP(ttl=drop_mid)/UDP(sport=drop_lo,dport=drop_hi)


sniff(iface="veth0", prn=lambda x:(x['IP'].src,  x['Ethernet'].src, x['IP'].dst) if x['Ethernet'].dst==':'.join(['00']*6) else None)
