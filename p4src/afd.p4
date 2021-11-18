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

    apply {
        // Choose a new threshold
        if (eg_md.afd.is_worker == 0) {
            threshold_interpolator.apply(eg_md.afd.scaled_pkt_len, eg_md.afd.vlink_id,
                                         eg_md.afd.bytes_sent_lo, eg_md.afd.bytes_sent_hi,
                                         eg_md.afd.threshold,
                                         eg_md.afd.threshold_lo, eg_md.afd.threshold_hi,
                                         eg_md.afd.candidate_delta_pow,
                                         eg_md.afd.new_threshold);
        }
        // If normal packet, save the new threshold. If a worker packet, load the new one
        dump_or_grab_new_threshold.apply();

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
