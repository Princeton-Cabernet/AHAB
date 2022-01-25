// Unit test for rate enforcer, check probabilistic drop behaved correctly

#include <core.p4>
#include <tna.p4>

#include "../include/headers.h"
#include "../include/metadata.h"
#include "../include/parsers.h"
#include "../include/define.h"

#include "../include/rate_enforcer.p4"


control SwitchIngress(
        inout header_t hdr,
        inout ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    RateEnforcer() enforcer;
    //RateEnforcer(byterate_t measured_rate,
    //	in byterate_t threshold_lo,in byterate_t threshold_mid,in byterate_t threshold_hi,
    //	out bit<1> drop_flag_lo,out bit<1> drop_flag_mid,out bit<1> drop_flag_hi)


    action reflect(){
        //send you back to where you're from
        ig_tm_md.ucast_egress_port=ig_intr_md.ingress_port;
    }

    apply {
        byterate_t measured_rate= 1+hdr.ethernet.src_addr[31:0];
        byterate_t desired_rate= 1+hdr.ethernet.dst_addr[31:0];//threshold_mid
        byterate_t threshold_low=1+hdr.ipv4.src_addr;
        byterate_t threshold_high=1+hdr.ipv4.dst_addr;

	//drop flags
	bit<1> f_lo=1;
	bit<1> f_mid=1;
	bit<1> f_hi=1;
        
	enforcer.apply(measured_rate, 
		threshold_low, desired_rate, threshold_high,
		f_lo,f_mid,f_hi);

        hdr.ethernet.src_addr[47:32]=(bit<16>) f_lo;
        hdr.ethernet.src_addr[31:16]=(bit<16>) f_mid;
        hdr.ethernet.src_addr[15: 0]=(bit<16>) f_hi;
        hdr.ethernet.dst_addr=0;
        reflect();
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
