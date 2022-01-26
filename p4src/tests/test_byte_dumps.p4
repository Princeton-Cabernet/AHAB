// Unit test for byte dumps

#include <core.p4>
#include <tna.p4>

#include "../include/headers.h"
#include "../include/metadata.h"
#include "../include/parsers.h"
#include "../include/define.h"

#include "../include/byte_dumps.p4"


control SwitchIngress(
        inout header_t hdr,
        inout ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    ByteDumps() byte_dumps;
	//control ByteDumps(in vlink_index_t vlink_id,
        //          in bytecount_t scaled_pkt_len,
        //          in bit<1> drop_flag_lo, in bit<1> drop_flag_mid, in bit<1> drop_flag_hi,
        //          out bytecount_t pkt_len_lo, out bytecount_t pkt_len_hi, out bytecount_t pkt_len_all)

    action reflect(){
        //send you back to where you're from
        ig_tm_md.ucast_egress_port=ig_intr_md.ingress_port;
    }

    afd_metadata_t afd_md;

    apply {

	if(hdr.ethernet.src_addr[47:40]==0xf1){
		afd_md.vlink_id=11;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len >> 1);
	}else
	if(hdr.ethernet.src_addr[47:40]==0xf2){
		afd_md.vlink_id=12;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len >> 2);
	}else
	if(hdr.ethernet.src_addr[47:40]==0x01){
		afd_md.vlink_id=1;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 1);
	}else
	if(hdr.ethernet.src_addr[47:40]==0x02){
		afd_md.vlink_id=2;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 2);
	}else{
		afd_md.vlink_id=0;
		afd_md.scaled_pkt_len=(bytecount_t) hdr.ipv4.total_len;
	}//simulate upstream shifts
	
	bit<1> drop_flag_lo=0;
	bit<1> drop_flag_mid=0;
	bit<1> drop_flag_hi=0;

	@in_hash{ drop_flag_lo= hdr.udp.src_port[0:0]^hdr.udp.src_port[1:1]; }
	@in_hash{ drop_flag_mid= hdr.ipv4.ttl[0:0]^hdr.ipv4.ttl[1:1]; }
	@in_hash{ drop_flag_hi= hdr.udp.dst_port[0:0]^hdr.udp.dst_port[1:1]; }

	bytecount_t pkt_len_lo;
	bytecount_t pkt_len_all;
	bytecount_t pkt_len_hi;
	
	byte_dumps.apply(afd_md.vlink_id, afd_md.scaled_pkt_len, 
		drop_flag_lo, drop_flag_mid, drop_flag_hi,
		pkt_len_lo,  pkt_len_hi,
		pkt_len_all
	);

	@in_hash{ hdr.ipv4.src_addr=pkt_len_lo; }
	@in_hash{ hdr.ipv4.dst_addr=pkt_len_hi; }
	@in_hash{ hdr.ethernet.src_addr[31:0]=(bit<32>) pkt_len_all; }

	
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
