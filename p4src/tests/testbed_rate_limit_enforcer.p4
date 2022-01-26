// Testbed program for per-flow rate limit, with probabilistic enforcer

#include <core.p4>
#include <tna.p4>

#include "../include/headers.h"
#include "../include/metadata.h"
#include "../include/parsers.h"
#include "../include/define.h"

#include "../include/rate_estimator.p4"
#include "../include/rate_enforcer.p4"


control SwitchIngress(
        inout header_t hdr,
        inout ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    RateEstimator() estimator;
    // RateEstimator(in bit<32> src_ip, in bit<32> dst_ip, in bit<8> proto, in bit<16> src_port, in bit<16> dst_port, 
    //      in  bytecount_t sketch_input, out byterate_t sketch_output) 
    // Calculates t_new = t_mid +- ( numerator / denominator ) * delta_t  // ( + if interp_right, - if interp_left)

    RateEnforcer() enforcer;

    action drop() {
        ig_dprsr_md.drop_ctl = 0x1; // Mark packet for dropping after ingress.
    }
    action route_to_port(bit<9> port){
        ig_tm_md.ucast_egress_port=port;
    }
    action testbed_route(){
        route_to_port((bit<9>) hdr.ipv4.dst_addr[7:0]);
    }

    apply {
	bytecount_t sketch_input=(bytecount_t) hdr.ipv4.total_len;
	byterate_t sketch_output=0;
	
        estimator.apply(
		hdr.ipv4.src_addr, hdr.ipv4.dst_addr, hdr.ipv4.protocol,
		ig_md.sport, ig_md.dport,
		sketch_input, sketch_output);
	// Fixed rate limit of 10Mbps
	// at default config (rate mode, 1e6 decay, 1 scale), the limit is about 1200

	byterate_t t_lo=1000*10;
	byterate_t t_mid=1200*10;
	byterate_t t_hi=1400*10;

	//drop flags
        bit<1> f_lo=1;
        bit<1> f_mid=1;
        bit<1> f_hi=1;

        enforcer.apply(sketch_output,
                t_lo,t_mid,t_hi,
                f_lo,f_mid,f_hi);
	
	if(f_mid==1){drop();} 
	hdr.ethernet.src_addr[31:0]=sketch_output;
	hdr.ethernet.src_addr[47:40]=(bit<8>) t_lo;
	hdr.ethernet.src_addr[39:32]=(bit<8>) t_hi;

	testbed_route();
    }
}


control SwitchEgress(
        inout header_t hdr,
        inout eg_metadata_t eg_md,
        in egress_intrinsic_metadata_t eg_intr_md,
        in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
        inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_oport_md) {

    apply {
    }
}


Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
