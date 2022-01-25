// Unit test for worker_generate. be careful what timestamps are used...

#include <core.p4>
#include <tna.p4>

#include "../include/headers.h"
#include "../include/metadata.h"
#include "../include/parsers.h"
#include "../include/define.h"

#include "../include/worker_generate.p4"


control SwitchIngress(
        inout header_t hdr,
        inout ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    WorkerGeneration() worker_gen;

    action reflect(){
        //send you back to where you're from
        ig_tm_md.ucast_egress_port=ig_intr_md.ingress_port;
    }

    afd_metadata_t afd_md;

    apply {
	epoch_t epoch = (epoch_t) ig_intr_md.ingress_mac_tstamp[47:20];//scale to 2^20ns ~= 1ms

	afd_md.vlink_id=(vlink_index_t) hdr.ipv4.dst_addr;
	afd_md.epoch=epoch;

	worker_gen.apply(afd_md); 

	if(afd_md.is_worker==1){
		hdr.ethernet.src_addr=48w0xaabbccddeeff;
	}else{
		hdr.ethernet.src_addr=0;
	}
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
