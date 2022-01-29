# Simulate threshold updates

import numpy as np

default_thres=1024

link_capacity=8192

flows_incoming_rate=[30000,50000]#per epoch


def simulate_drop_rate(measured_rate, threshold_lo, threshold_mid, threshold_hi):#assume congestion flag is trur
	#returns prob_lo,prob_mid,prob_hi
	#TODO: use tofino-accurate drop. is there a module for it?
	shift_basis=max([2**i for i in range(32) if 2**i<=measured_rate])
	if shift_basis<32:
		return [0]*3
	#maintain highest 3 bits
	shifted_rate=(measured_rate/shift_basis*32) //1 
	shifted_t_lo=(threshold_lo/shift_basis*32) //1 
	shifted_t_mid=(threshold_mid/shift_basis*32) //1 
	shifted_t_hi=(threshold_hi/shift_basis*32) //1 
	#formula: drop rate=1-min(1, j/i)
	# survived=send * min(1, j/i)
	p_lo=1-min(1,shifted_t_lo/shifted_rate) 
	p_mid=1-min(1,shifted_t_mid/shifted_rate) 
	p_hi=1-min(1,shifted_t_hi/shifted_rate) 
	if measured_rate < threshold_lo:
		p_lo=0	
	if measured_rate < threshold_mid:
		p_mid=0
	if measured_rate < threshold_hi:
		p_hi=0
	return [p_lo,p_mid,p_hi]


def expand_threshold_candidates(threshold):
	if threshold<=16: return [threshold,threshold,threshold+16]
	if threshold>=16777216: return [threshold-8388612,threshold,threshold]
	delta=max([2**(i-1) for i in range(32) if 2**i<=threshold])
	return [threshold-delta,threshold,threshold+delta]


def interpolate(rate_lo, rate_mid, rate_hi, target_rate, thres_lo, thres_mid, thres_hi, naive=False):
	#ideal for now
	if target_rate <= rate_lo:
		return "Choose low",thres_lo
	if target_rate >= rate_hi:
		return "Choose hi",thres_hi
	if target_rate ==rate_mid:
		return "Choose mid",thres_mid
	if naive:
		if target_rate <=rate_mid:
			return "Naive left",thres_lo
		if target_rate >=rate_mid:
			return "Naive right",thres_hi
	if target_rate <=rate_mid:
		interp=(rate_mid-target_rate)/(rate_mid-rate_lo) *(thres_mid-thres_lo)
		return "Interp left",int(thres_mid-interp)
	if target_rate >=rate_mid:
		interp=(target_rate-rate_mid)/(rate_hi-rate_mid) *(thres_hi-thres_mid)
		return "Interp right",int(thres_mid+interp)

#init
t, threshold, congestion_flag, last_demand, last_rate=0,default_thres,0,0,0

while True:
	t+=1
	print(f"t={t}  congestion_flag={congestion_flag}, threshold=",expand_threshold_candidates(threshold))
	#how many bytes are sent this epoch?
	bytes_lo,bytes_mid,bytes_hi,bytes_demand=0,0,0,0

	for f in flows_incoming_rate:
		bytes_demand+=f
		if congestion_flag==0:
			bytes_lo+=f
			bytes_mid+=f
			bytes_hi+=f
		else:
			p_lo,p_mid,p_hi=simulate_drop_rate(f, *expand_threshold_candidates(threshold))
			#print(f'f={f} drop rates',p_lo,p_mid,p_hi)
			bytes_lo+=int(f*(1-p_lo))
			bytes_mid+=int(f*(1-p_mid))
			bytes_hi+=int(f*(1-p_hi))

	if bytes_demand > link_capacity:
		congestion_flag=1
	print(f'Sent bytes mid={bytes_mid}')#, lo/hi={bytes_lo}/{bytes_hi}')
	last_rate=bytes_demand

	msg,threshold=interpolate(
		bytes_lo,bytes_mid,bytes_hi, 
		link_capacity,
		*expand_threshold_candidates(threshold)
		)
	#print(f'Interpolated new threshold: {msg} {threshold}')

	if t>50:break