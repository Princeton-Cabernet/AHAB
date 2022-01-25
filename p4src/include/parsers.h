#pragma once
//== Parsers and Deparsers

parser TofinoIngressParser(
        packet_in pkt,
        inout ig_metadata_t ig_md,
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
        pkt.advance(64);
        transition accept;
    }

    state parse_port_metadata {
        pkt.advance(64);  //tofino 1 port metadata size
        transition accept;
    }
}
parser SwitchIngressParser(
        packet_in pkt,
        out header_t hdr,
        out ig_metadata_t ig_md,
        out ingress_intrinsic_metadata_t ig_intr_md) {

    TofinoIngressParser() tofino_parser;

    state start {
        tofino_parser.apply(pkt, ig_md, ig_intr_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select (hdr.ethernet.ether_type) {
            ETHERTYPE_THRESHOLD_UPDATE : parse_threshold_update;
            ETHERTYPE_IPV4 : parse_ipv4;
            default : reject;
        }
    }

    state parse_threshold_update {
        pkt.extract(hdr.afd_update);

        // Place the update fields where control vlink_lookup expects them
        ig_md.afd.new_threshold = hdr.afd_update.new_threshold;
        ig_md.afd.vlink_id = hdr.afd_update.vlink_id;
        ig_md.afd.congestion_flag = hdr.afd_update.congestion_flag;
        ig_md.afd.is_worker = 1;

        transition accept;
    }


    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTOCOLS_TCP : parse_tcp;
            IP_PROTOCOLS_UDP : parse_udp;
            default : parse_unknown_l4;
        }
    }

    state parse_tcp {
        pkt.extract(hdr.tcp);
        ig_md.sport = hdr.tcp.src_port;
        ig_md.dport = hdr.tcp.dst_port;
        transition accept;
    }

    state parse_udp {
        pkt.extract(hdr.udp);
        ig_md.sport = hdr.udp.src_port;
        ig_md.dport = hdr.udp.dst_port;
        transition accept;
    }

    state parse_unknown_l4 {
        ig_md.sport = 0;
        ig_md.dport = 0;
        transition accept;
    }

}

control SwitchIngressDeparser(
        packet_out pkt,
        inout header_t hdr,
        in ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md) {

    Mirror() mirror;

    apply {


        if (ig_dprsr_md.mirror_type == MIRROR_TYPE_I2E) {
            // mirror the contents of a mirror_h header
            mirror.emit<mirror_h>(ig_md.ig_mir_ses, 
                                  {ig_md.afd.pkt_type, ig_md.afd.vlink_id});
        }

        pkt.emit(ig_md.afd);  // bridge the AFD metadata to egress
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4);
        pkt.emit(hdr.tcp);
        pkt.emit(hdr.udp);
    }
}

parser SwitchEgressParser(
        packet_in pkt,
        out header_t hdr,
        out eg_metadata_t eg_md,
        out egress_intrinsic_metadata_t eg_intr_md) {

    state start {
        pkt.extract(eg_intr_md); 
        transition parse_metadata;
    }

    state parse_metadata {
        mirror_h mirror_md = pkt.lookahead<mirror_h>();
        transition select(mirror_md.pkt_type) {
            PKT_TYPE_MIRROR : parse_mirror_md;
            PKT_TYPE_NORMAL : parse_bridged_md;
            default : accept;
        }
    }
    
    state parse_mirror_md {
        mirror_h mirror_md;
        pkt.extract(mirror_md);

        eg_md.afd.is_worker = 1;
        // Move mirrored header fields to their expected locations.
        eg_md.afd.packet_type = mirror_md.pkt_type;
        eg_md.afd.vlink_id = mirror_md.vlink_id;
        
        transition accept;
    }

    state parse_bridged_md {
        pkt.extact(eg_md.afd);
        transition accept;
    }

}

control SwitchEgressDeparser(
        packet_out pkt,
        inout header_t hdr,
        in eg_metadata_t eg_md,
        in egress_intrinsic_metadata_for_deparser_t eg_intr_md_for_dprsr) {
    apply {
        pkt.emit(hdr.fake_ethernet);  // signals to ingress that this is an update
        pkt.emit(hdr.afd_update);  // update values
    }
}
