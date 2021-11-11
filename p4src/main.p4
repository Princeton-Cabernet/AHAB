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
#include "threshold_interpolator.p4"


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
        rate_estimator.apply(hdr.ipv4.src,
                             hdr.ipv4.dst,
                             hdr.ipv4.proto,
                             ig_md.sport,
                             ig_md.dport,
                             ig_md.afd.scaled_pkt_len,
                             ig_md.afd.measured_rate);
        bit<1> afd_drop_flag
        rate_enforcer.apply(ig_md.afd, afd_drop_flag);
        if (afd_drop_flag == 1) {
            // TODO: send to low-priority queue instead of outright dropping
            ig_dprsr_md.drop_ctl = 1;
    }
    // TODO: bridge afd metadata
}


control SwitchEgress(
        inout header_t hdr,
        inout eg_metadata_t eg_md,
        in egress_intrinsic_metadata_t eg_intr_md,
        in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
        inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_oport_md) {

    ThresholdInterpolator() threshold_interpolator;

    apply {
        // Choose a new threshold
        threshold_interpolator.apply(eg_md.afd);
        if (eg_md.afd.is_worker == 1) {
            // TODO: recirculate afd_md.threshold_new back to ingress
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
