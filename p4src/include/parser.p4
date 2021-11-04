/*******************************************************************************
 * BAREFOOT NETWORKS CONFIDENTIAL & PROPRIETARY
 *
 * Copyright (c) 2019-present Barefoot Networks, Inc.
 *
 * All Rights Reserved.
 *
 * NOTICE: All information contained herein is, and remains the property of
 * Barefoot Networks, Inc. and its suppliers, if any. The intellectual and
 * technical concepts contained herein are proprietary to Barefoot Networks, Inc.
 * and its suppliers and may be covered by U.S. and Foreign Patents, patents in
 * process, and are protected by trade secret or copyright law.  Dissemination of
 * this information or reproduction of this material is strictly forbidden unless
 * prior written permission is obtained from Barefoot Networks, Inc.
 *
 * No warranty, explicit or implicit is provided, unless granted under a written
 * agreement with Barefoot Networks, Inc.
 *
 ******************************************************************************/

#include <core.p4>
#include <tna.p4>

#include "headers.p4"

parser TofinoIngressParser(
        packet_in pkt,
        out ig_md,
        out ingress_intrinsic_metadata_t ig_intr_md) {
    state start {
        pkt.extract(ig_intr_md);
        transition select(ig_intr_md.resubmit_flag) {
            1 : parse_resubmit;
            0 : parse_port_metadata;
        }
    }

    state parse_resubmit {
        // Parse resubmitted packet here.
        pkt.extract(ig_md.resubmit_md);
        transition accept;
    }

    state parse_port_metadata {
        pkt.advance(PORT_METADATA_SIZE);
        transition accept;
    }
}

parser TofinoEgressParser(
        packet_in pkt,
        out eg_md,
        out egress_intrinsic_metadata_t eg_intr_md) {
    state start {
        pkt.extract(eg_intr_md);
        common_egress_metadata_t common_eg_md = packet.lookahead<common_egress_metadata_t>();
        transition select(common_eg_md.bmd_type, common_eg_md.mirror_type) {
            (BridgedMdType_t.INGRESS_TO_EGRESS, _): parse_bridged_md;
            (BridgedMdType_t.EGRESS_MIRROR, _): parse_egress_mirror;
            default: reject;
        }
    }

    state parse_bridged_md {
        pkt.extract(eg_md.bridged);
        transition accept;
    }

    state parse_egress_mirror {
        pkt.extract(eg_md.egress_mirror);
        transition accept;
    }
}



// Skip egress
control BypassEgress(inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    action set_bypass_egress() {
        ig_tm_md.bypass_egress = 1w1;
    }

    table bypass_egress {
        actions = {
            set_bypass_egress();
        }
        const default_action = set_bypass_egress;
    }

    apply {
        bypass_egress.apply();
    }
}



// ---------------------------------------------------------------------------
// Ingress parser
// ---------------------------------------------------------------------------
parser SwitchIngressParser(
        packet_in pkt,
        out header_t hdr,
        out metadata_t ig_md,
        out ingress_intrinsic_metadata_t ig_intr_md) {
    TofinoIngressParser() tofino_parser;

    state start {
        tofino_parser.apply(pkt, ig_md, ig_intr_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition accept;
    }
}

// ---------------------------------------------------------------------------
// Ingress Deparser
// ---------------------------------------------------------------------------
control SwitchIngressDeparser(
        packet_out pkt,
        inout header_t hdr,
        in ingress_metadata_t ig_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {

    apply {
        pkt.emit(hdr);
    }
}

parser SwitchEgressParser(
    packet_in pkt,
    out header_t hdr,
    out egress_metadata_t eg_md,
    out egress_intrinsic_metadata_t eg_intr_md) {
    TofinoEgressParser() tofino_parser;

    state start {
        tofino_parser.apply(pkt, eg_md, eg_intr_md);
        transition parse_ethernet {
            pkt.extract(hdr.ethernet);
            transition accept;
        }
    }
}

control EgressMirror(
    in egress_headers_t hdr,
    in egress_metadata_t eg_md,
    in egress_intrinsic_metadata_for_deparser_t eg_intr_md_for_dprsr) {
    Mirror() mirror;
    apply {
        if (eg_intr_md_for_dprsr.mirror_type == (bit<3>MirrorType_t.QUEUE_REPORT) {
            mirror.emit<queue_report_metadata_t>(eg_md.bridged.mirror_session_id,
                                                 eg_md.queue_report_md);
        }
    }

control SwitchEgressDeparser(packet_out pkt,
    inout egress_headers_t hdr,
    in egress_metadata_t eg_md,
    in egress_intrinsic_metadata_for_deparser_t eg_intr_md_for_dprsr) {

    EgressMirror() gress_mirror;

    apply {
        egress_mirror.apply(hdr, eg_md, eg_intr_md_for_dprsr);

        packet.emit(hdr);
    }
}
    
