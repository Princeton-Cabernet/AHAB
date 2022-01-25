// Unit test for interpolation

#include <core.p4>
#include <tna.p4>

#include "../include/headers.h"
#include "../include/metadata.h"
#include "../include/parsers.h"
#include "../include/define.h"

#include "../include/threshold_interpolator.p4"


control SwitchIngress(
        inout header_t hdr,
        inout ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    InterpolateFairRate() interpolator;
    //InterpolateFairRate(in byterate_t numerator, in byterate_t denominator, in byterate_t t_mid,
    //                       in exponent_t delta_t_log, out byterate_t t_new, in InterpolationOp interp_op) {
    // Calculates t_new = t_mid +- ( numerator / denominator ) * delta_t  // ( + if interp_right, - if interp_left)


    action reflect(){
        //send you back to where you're from
        ig_tm_md.ucast_egress_port=ig_intr_md.ingress_port;
    }

    apply {
        byterate_t numerator= hdr.ethernet.src_addr[31:0];
        byterate_t denominator= hdr.ethernet.dst_addr[31:0];
        byterate_t t_mid=hdr.ipv4.src_addr;
        exponent_t delta_t_log=(exponent_t) hdr.udp.src_port;
        byterate_t t_new=0;
        
        InterpolationOp interp_op=InterpolationOp.NONE;//NONE = 0x0,LEFT = 0x1,RIGHT = 0x2
        if(hdr.udp.dst_port==1){
            interp_op=InterpolationOp.LEFT;
        }else if(hdr.udp.dst_port==2){
            interp_op=InterpolationOp.RIGHT;
        }

        interpolator.apply(numerator, denominator, t_mid, delta_t_log, t_new, interp_op);
        
        hdr.ipv4.dst_addr=t_new;

        hdr.ethernet.src_addr=0;
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
