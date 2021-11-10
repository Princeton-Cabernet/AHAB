// Approx UPF. Copyright (c) Princeton University, all rights reserved

#include <core.p4>
#include <tna.p4>

#include "headers.h"
#include "metadata.h"
#include "parsers.h"
#include "define.h"

#include "vlink_lookup.p4"
#include "rate_estimator.p4"
#include "rate_enforcer.p4"
#include "threshold_memory.p4"
#include "histogram_interpolate.p4"


/* TODO: where should the packet cloning occur?
We should begin choosing a new candidate as soon as the window jumps.
To detect the jump, we'll need a register that stores "last epoch updated" per-vlink.
The window
*/

/*
Tofino-Approximate fair dropping:
- Load slice threshold, scale-up packet length:
- Approximate flow rate using a decaying CMS
- Set drop flag with probability 1 - min(1, T/Rate)
- Feed non-dropped packets into a rate-measuring LPF
- Adjust threshold based upon LPF output, using EWMA recurrence from AFD paper
*/



control SwitchIngress(
        inout header_t hdr,
        inout ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    VLink_Find() vlink_find;
    Become_Worker_Check() become_worker_check;
    PerFlow_Rate_Estimator() perflow_rate_estimator;
    Threshld_Memory() threshold_memory;

    Get_Neighbouring_Slice() get_neighbouring_slice;
    Histogram_Three_Slice() histogram_this_vlink;

    apply {
        epoch_t epoch = (epoch_t) ig_intr_md.ingress_mac_tstamp[47:20];//scale to 2^20ns ~= 1ms


        // this is regular workflow, not considering recirculation for now

        vlink_index_t vlink_index;
        bytecount_t scaled_weight;
        vlink_find.apply(hdr,vlink_index,scaled_weight);

        bool become_worker;
        become_worker_check.apply(vlink_index, epoch, become_worker);

        bit<32> flowID = hdr.ipv4.dst_addr;
        bytecount_t perflow_rate;
        perflow_rate_estimator.apply(flowID, epoch, scaled_weight, perflow_rate);

        bytecount_t this_epoch_threshold;
        threshold_memory.apply(vlink_index, false, this_epoch_threshold);//read into per_flow_threshold

        bytecount_t low_slice_thres;
        bytecount_t high_slice_thres;
        bit<8> log_offset;
        get_neighbouring_slice.apply(this_epoch_threshold,low_slice_thres,high_slice_thres,log_offset);


        bytecount_t new_C=65000;
        bytecount_t new_T;
        if(become_worker){
            //interpolate the new threshold!
             //first get the new capacity for this VLink.
              //for now use constant new_C.
              //new_C=65000;
        }else{
            //new_C=0;//doesn't matter in this branch
        }

        histogram_this_vlink.apply(vlink_index, perflow_rate, scaled_weight,
                this_epoch_threshold,low_slice_thres,high_slice_thres,log_offset, //mid,low,high,
                become_worker,//is_readout,
                new_C,
                new_T);
        
        if(become_worker){
            // TODO: recirculate to put new_T into memory
        }
        
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
        // Load vlink capacity
        // Update candidate counters and/or choose a winning candidate threshold
        // Dump winning candidate threshold into mirrored+recirculated packet
    }
}



Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
