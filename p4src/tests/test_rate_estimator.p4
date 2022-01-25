// Unit test for interpolation

#include <core.p4>
#include <tna.p4>

#include "../include/headers.h"
#include "../include/metadata.h"
#include "../include/parsers.h"
#include "../include/define.h"

#include "../include/rate_estimator.p4"


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


    action reflect(){
        //send you back to where you're from
        ig_tm_md.ucast_egress_port=ig_intr_md.ingress_port;
    }

    apply {

	//assert UDP
	bytecount_t sketch_input=(bytecount_t) hdr.ipv4.total_len;
	byterate_t sketch_output=0;
	estimator.apply(
		hdr.ipv4.src_addr,hdr.ipv4.dst_addr,hdr.ipv4.protocol,hdr.udp.src_port,hdr.udp.dst_port,
		sketch_input,sketch_output	
	);	

        hdr.ethernet.src_addr=(bit<48>)sketch_output;
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
