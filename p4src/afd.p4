// Approx UPF. Copyright (c) Princeton University, all rights reserved

#include <core.p4>
#include <tna.p4>

#include "include/headers.h"
#include "include/metadata.h"
#include "include/parsers.h"
#include "include/define.h"

#include "include/vlink_lookup.p4"
#include "include/rate_estimator.p4"
#include "include/rate_enforcer.p4"
#include "include/threshold_interpolator.p4"
#include "include/max_rate_estimator.p4"
#include "include/link_rate_tracker.p4"


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

    apply {
        epoch_t epoch = (epoch_t) ig_intr_md.ingress_mac_tstamp[47:20];//scale to 2^20ns ~= 1ms


        // this is regular workflow, not considering recirculation for now
        vlink_lookup.apply(hdr, ig_md.afd);
        rate_estimator.apply(hdr.ipv4.src_addr,
                             hdr.ipv4.dst_addr,
                             hdr.ipv4.protocol,
                             ig_md.sport,
                             ig_md.dport,
                             ig_md.afd.scaled_pkt_len,
                             ig_md.afd.measured_rate);



        bit<1> afd_drop_flag;
        rate_enforcer.apply(ig_md.afd, afd_drop_flag);
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

    bytrate_t vlink_rate;
    bytrate_t vlink_rate_lo;
    bytrate_t vlink_rate_hi;
    bytrate_t vlink_demand;


    action load_vtrunk_fair_rate(byterate_t vtrunk_fair_rate) {
        eg_md.afd.vtrunk_threshold = vtrunk_threshold;
    }
    table vtrunk_lookup {
        key = {
            vtrunk_id : exact;
        }
        actions = {
            load_vtrunk_fair_rate;
        }
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
    Register<bit<1>, vlink_index_t>(size=NUM_VLINKS) congestion_flags;
    RegisterAction<bit<1>, vlink_index_t, bit<1>>(congestion_flags) dump_congestion_flag_regact = {
        void apply(inout bit<1> stored_flag, out bit<1> returned_flag) {
            if (demand_delta >= BYTERATE_T_SIGN_BIT) {
                stored_flag = 1;
            } else {
                stored_flag = 0;
            }
        }
    };
    RegisterAction<bit<1>, vlink_index_t, bit<1>>(congestion_flags) grab_congestion_flag_regact = {
        void apply(inout bit<1> stored_flag, out bit<1> returned_flag) {
            returned_flag = stored_flag;
        }
    };
    @hidden
    action dump_congestion_flag() {
        dump_congestion_flag_regact.execute(eg_md.afd.vlink_id);
    }
    @hidden
    action grab_congestion_flag() {
        eg_md.afd.congestion_flag = grab_congestion_flag_regact.execute(eg_md.afd.vlink_id);
    }
    @hidden
    table dump_or_grab_congestion_flag {
        key = {
            eg_md.afd.is_worker : exact;
        }
        actions = {
            dump_congestion_flag;
            grab_congestion_flag;
        }
        const entries = {
            0 : dump_congestion_flag();
            1 : grab_congestion_flag();
        }
        size = 2;
    }


    apply {
        // TODO: check if current rate exceeds vtrunk's threshold, and set a congestion flag accordingly
        // Choose a new threshold
        // TODO: differentiate between an end-of-window packet that triggers clones, and actual clones
        // Two different kinds of workers
        link_rate_tracker.apply(eg_md.afd.vlink_id,
                                eg_md.afd.scaled_pkt_len, eg_md.afd.bytes_sent_all,
                                eg_md.afd.bytes_sent_lo, eg_md.afd.bytes_sent_hi,
                                vlink_rate, vlink_rate_lo, vlink_rate_hi, 
                                vlink_demand);
        if (eg_md.afd.is_worker == 0) {
            vtrunk_lookup.apply();
            demand_delta = eg_md.afd.vtrunk_threshold - vlink_demand; 
            max_rate_estimator.apply(eg_md.afd.vlink_id,
                                     eg_md.afd.measured_rate,
                                     eg_md.afd.is_worker,
                                     eg_md.afd.max_rate);
            threshold_interpolator.apply(eg_md.afd.scaled_pkt_len, eg_md.afd.vlink_id,
                                         eg_md.afd.bytes_sent_lo, eg_md.afd.bytes_sent_hi,
                                         eg_md.afd.vtrunk_threshold, eg_md.afd.threshold,
                                         eg_md.afd.threshold_lo, eg_md.afd.threshold_hi,
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
            // TODO: recirculate eg_md.afd.new_threshold to every ingress pipe
        }
    }
}



Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
