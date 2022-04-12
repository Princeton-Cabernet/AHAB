#!/bin/bash
DEV='enp134s0f1'

sudo tc qdisc del dev $DEV root #reset

sudo tc qdisc add dev $DEV root handle 1: htb
sudo tc class add dev $DEV parent 1: classid 1:1 htb rate 100gbit # this is for all other traffic.
for I in `seq 1 20`; do
    PORT=`expr 9000 + ${I}`;
    #LATENCY=`python3 -c "print(${I}/10)"`
    LATENCY=0

    echo "Setting latency ${LATENCY}ms for TCP dport ${PORT}"
    sudo -E tc class add dev $DEV parent 1: classid 1:${PORT} htb rate 100gbit
    sudo -E tc filter add dev $DEV parent 1: protocol ip prio 1 u32 flowid 1:${PORT} match ip dport ${PORT} 0xffff
    sudo -E tc qdisc add dev $DEV parent 1:${PORT} handle ${PORT}:1 netem delay ${LATENCY}ms
done
