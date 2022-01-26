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

        vlink_lookup.apply(hdr, ig_md.afd);

        if (ig_md.afd.is_worker == 1) {
            // If is_worker is already set, then this packet was a recirculation.
            // A recirculated packet's only job is to write a new threshold,
            // which just happened in vlink_lookup, so time to drop.
            ig_dprsr_md.drop_ctl = 1;
            exit;
        }

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
        // If congestion flag is false, dropping is disabled
        if (ig_md.afd.congestion_flag == 0) {
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
        }
        if (afd_drop_flag == 1) {
            // TODO: send to low-priority queue instead of outright dropping
            ig_dprsr_md.drop_ctl = 1;
        }
        // TODO: bridge afd metadata

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

    @hidden
    Register<byterate_t, vlink_index_t>(size=NUM_VLINKS) winning_thresholds;
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(winning_thresholds) grab_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            retval = stored;
        }
    };
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(winning_thresholds) dump_new_threshold_regact = {
        void apply(inout byterate_t stored) {
            stored = eg_md.afd.new_threshold;
        }
    };
    @hidden
    action grab_new_threshold() {
        eg_md.afd.new_threshold = grab_new_threshold_regact.execute(eg_md.afd.vlink_id);
    }
    @hidden
    action dump_new_threshold() {
        dump_new_threshold_regact.execute(eg_md.afd.vlink_id);
    }
    @hidden
    table dump_or_grab_new_threshold {
        key = {
            eg_md.afd.is_worker : exact;
        }
        actions = {
            dump_new_threshold;
            grab_new_threshold;
        }
        const entries = {
            0 : dump_new_threshold();
            1 : grab_new_threshold();
        }
        size = 2;
    }

    byterate_t demand_delta; 
    @hidden
    Register<bit<8>, vlink_index_t>(size=NUM_VLINKS) congestion_flags;
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) set_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag) {
	    stored_flag = 1;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) unset_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag) {
	    stored_flag = 0;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) grab_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
            returned_flag = stored_flag;
        }
    };
    @hidden
    action set_congestion_flag() {
        set_congestion_flag_regact.execute(eg_md.afd.vlink_id);
    }
    @hidden
    action unset_congestion_flag() {
        unset_congestion_flag_regact.execute(eg_md.afd.vlink_id);
    }
    @hidden
    action grab_congestion_flag() {
        eg_md.afd.congestion_flag = grab_congestion_flag_regact.execute(eg_md.afd.vlink_id);
    }
#define TERNARY_NEG_CHECK 32w0x80000000 &&& 32w0x80000000
#define TERNARY_POS_CHECK 32w0 &&& 32w0x80000000
#define TERNARY_DONT_CARE 32w0 &&& 32w0
    @hidden
    table dump_or_grab_congestion_flag {
        key = {
            eg_md.afd.is_worker : exact;
            demand_delta : ternary;
        }
        actions = {
            set_congestion_flag;
            unset_congestion_flag;
            grab_congestion_flag;
        }
        const entries = {
            (0, TERNARY_NEG_CHECK) : set_congestion_flag();
            (0, TERNARY_POS_CHECK) : unset_congestion_flag();
            (1, TERNARY_DONT_CARE) : grab_congestion_flag();
        }
        size = 3;
    }


    apply {
        if (eg_md.afd.is_worker == 0) {
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
            vtrunk_lookup.apply();
            demand_delta = eg_md.afd.vtrunk_threshold - vlink_demand; 
            max_rate_estimator.apply(eg_md.afd.vlink_id,
                                     eg_md.afd.measured_rate,
                                     eg_md.afd.is_worker,
                                     eg_md.afd.max_rate);
            threshold_interpolator.apply(vlink_rate, 
                                         vlink_rate_lo, 
                                         vlink_rate_hi,
                                         eg_md.afd.vtrunk_threshold, 
                                         eg_md.afd.threshold,
                                         eg_md.afd.threshold_lo, 
                                         eg_md.afd.threshold_hi,
                                         eg_md.afd.candidate_delta_pow,
                                         eg_md.afd.new_threshold);
        }
        // If the highest rate seen recently is lower than the new threshold, lower the threshold to that rate
        // This prevents the threshold from jumping to infinity during times of underutilization,
        // which improves convergence rate.
        // TODO: should we smooth this out?
        eg_md.afd.new_threshold = min<byterate_t>(eg_md.afd.new_threshold, eg_md.afd.max_rate);
        // If normal packet, save the new threshold. If a worker packet, load the new one
        dump_or_grab_new_threshold.apply();
        dump_or_grab_congestion_flag.apply();

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
