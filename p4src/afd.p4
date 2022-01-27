// Approx UPF. Copyright (c) Princeton University, all rights reserved

#include <core.p4>
#include <tna.p4>

#include "include/define.h"
#include "include/headers.h"
#include "include/metadata.h"
#include "include/parsers.h"

#include "include/vlink_lookup.p4"
#include "include/rate_estimator.p4"
#include "include/rate_enforcer.p4"
#include "include/threshold_interpolator.p4"
#include "include/max_rate_estimator.p4"
#include "include/link_rate_tracker.p4"
#include "include/byte_dumps.p4"
#include "include/worker_generator.p4"
#include "include/update_storage.p4"


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

    VLinkLookup() vlink_lookup;
    RateEstimator() rate_estimator;
    RateEnforcer() rate_enforcer;
    ByteDumps() byte_dumps;
    WorkerGenerator() worker_generator;

    apply {
        epoch_t epoch = (epoch_t) ig_intr_md.ingress_mac_tstamp[47:20];//scale to 2^20ns ~= 1ms

	// If the packet is a recirculated update, it will not survive vlink_lookup.
        vlink_lookup.apply(hdr, ig_md.afd, ig_tm_md.ucast_egress_port, ig_dprsr_md.drop_ctl);

        bit<1> work_flag;
        worker_generator.apply(epoch, ig_md.afd.vlink_id, work_flag);
        if (work_flag == 1) {
            // A mirrored packet will be generated during deparsing
            ig_dprsr_md.mirror_type = MIRROR_TYPE_I2E;
            ig_md.mirror_session = THRESHOLD_UPDATE_MIRROR_SESSION;
            ig_md.mirror_bmd_type = BMD_TYPE_MIRROR;  // mirror digest fields cannot be immediates, so put this here
        } 

        // Approximately measure this flow's instantaneous rate.
        rate_estimator.apply(hdr.ipv4.src_addr,
                             hdr.ipv4.dst_addr,
                             hdr.ipv4.protocol,
                             ig_md.sport,
                             ig_md.dport,
                             ig_md.afd.scaled_pkt_len,
                             ig_md.afd.measured_rate);


        // Get real drop flag and two simulated drop flags
        bit<1> afd_drop_flag_lo;
        bit<1> afd_drop_flag;
        bit<1> afd_drop_flag_hi;
        rate_enforcer.apply(ig_md.afd.measured_rate,
                            ig_md.afd.threshold_lo,
                            ig_md.afd.threshold,
                            ig_md.afd.threshold_hi,
                            afd_drop_flag_lo,
                            afd_drop_flag,
                            afd_drop_flag_hi);
        if (ig_md.afd.congestion_flag == 0) {
	    // If congestion flag is false, dropping is disabled
            ig_md.afd.drop_withheld = afd_drop_flag;
            afd_drop_flag = 0;
        } else { // Dropping is enabled
            // Deposit or pick up packet bytecounts to allow the lo/hi drop
            // simulations to work around true dropping.
            byte_dumps.apply(ig_md.afd.vlink_id,
                             ig_md.afd.scaled_pkt_len,
                             afd_drop_flag_lo,
                             afd_drop_flag,
                             afd_drop_flag_hi,
                             ig_md.afd.bytes_sent_lo,
                             ig_md.afd.bytes_sent_hi,
                             ig_md.afd.bytes_sent_all);
            if (afd_drop_flag == 1) {
                // TODO: send to low-priority queue instead of outright dropping
                ig_dprsr_md.drop_ctl = 1;
            }
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

    ThresholdInterpolator() threshold_interpolator;
    MaxRateEstimator() max_rate_estimator;
    LinkRateTracker() link_rate_tracker;
    UpdateStorage() update_storage;

    byterate_t vlink_rate;
    byterate_t vlink_rate_lo;
    byterate_t vlink_rate_hi;
    byterate_t vlink_demand;


    action load_vtrunk_fair_rate(byterate_t vtrunk_fair_rate) {
        eg_md.afd.vtrunk_threshold = vtrunk_fair_rate;
    }
    table vtrunk_lookup {
        key = {
            // TODO: assign this in the vlink lookup stage in ingress
            eg_md.afd.vtrunk_id : exact;
        }
        actions = {
            load_vtrunk_fair_rate;
        }
        default_action = load_vtrunk_fair_rate(DEFAULT_VLINK_CAPACITY);
        size = NUM_VTRUNKS;
    }

#define TERNARY_NEG_CHECK 32w0x80000000 &&& 32w0x80000000
#define TERNARY_POS_CHECK 32w0 &&& 32w0x80000000
#define TERNARY_ZERO_CHECK 32w0 &&& 32w0xffffffff
#define TERNARY_DONT_CARE 32w0 &&& 32w0
bit<32> drate;

action choose_lo(){
    eg_md.afd.new_threshold=vlink_rate_lo;
}action choose_hi(){
    eg_md.afd.new_threshold=vlink_rate_hi;
}action choose_nop(){
    eg_md.afd.new_threshold=vlink_rate;
}

table naive_interpolate {
        key = {
            drate : ternary;
        }
        actions = {
            choose_lo;
            choose_nop;
            choose_hi;
        }
        const entries = {
            (TERNARY_NEG_CHECK) : choose_lo();     
            (TERNARY_POS_CHECK) : choose_hi();    
            (TERNARY_ZERO_CHECK) : choose_nop();
        }
        size = 8;
        default_action = choose_nop();  // Something went wrong, stick with the current fair rate threshold
    }
    apply { 
        if (eg_md.afd.is_worker == 0) {
            vtrunk_lookup.apply();
            link_rate_tracker.apply(eg_md.afd.vlink_id, 
                                    eg_md.afd.drop_withheld,
                                    eg_md.afd.scaled_pkt_len, 
                                    eg_md.afd.bytes_sent_all,
                                    eg_md.afd.bytes_sent_lo, 
                                    eg_md.afd.bytes_sent_hi,
                                    vlink_rate, 
                                    vlink_rate_lo, 
                                    vlink_rate_hi, 
                                    vlink_demand);

            drate    = vlink_rate    - eg_md.afd.vtrunk_threshold;

            naive_interpolate.apply();
        }
        // Load or save congestion flags and new thresholds
        update_storage.apply(eg_md.afd.vlink_id,
                             vlink_demand,
                             eg_md.afd.vtrunk_threshold,
                             0,
                             eg_md.afd.new_threshold,
                             eg_md.afd.is_worker,
                             eg_md.afd.congestion_flag);

        // Populate recirculation headers
        if (eg_md.afd.is_worker == 1) {
            // Fake ethernet header signals to ingress that this is an update
            hdr.fake_ethernet.setValid();
            hdr.fake_ethernet.ether_type = ETHERTYPE_THRESHOLD_UPDATE;
            hdr.fake_ethernet.src_addr = 48w0;
            hdr.fake_ethernet.dst_addr = 48w0;
            // The update
            hdr.afd_update.setValid();
            hdr.afd_update.vlink_id = eg_md.afd.vlink_id;
            hdr.afd_update.new_threshold = eg_md.afd.new_threshold;
            hdr.afd_update.congestion_flag = eg_md.afd.congestion_flag;
        }else{
            hdr.fake_ethernet.setInvalid();
            hdr.afd_update.setInvalid();
        }
        // TODO: recirculate to every ingress pipe, not just one.
    }
}



Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
