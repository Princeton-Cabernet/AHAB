/*
    AHAB project
    Copyright (c) 2022, Robert MacDavid, Xiaoqi Chen, Princeton University.
    macdavid [at] cs.princeton.edu
    License: AGPLv3
*/

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
	ig_md.afd.setValid();
        ig_md.afd.bmd_type = BMD_TYPE_I2E;
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select (hdr.ethernet.ether_type) {
            ETHERTYPE_THRESHOLD_UPDATE : parse_threshold_update;
            ETHERTYPE_IPV4 : parse_not_threshold_update;
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

        pkt.extract(hdr.fake_ethernet);
        transition parse_ipv4;
    }

    state parse_not_threshold_update {
        ig_md.afd.new_threshold = 0;
        ig_md.afd.vlink_id = 0;
        ig_md.afd.congestion_flag = 0;
        ig_md.afd.is_worker = 0;
        transition parse_ipv4;
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTOCOLS_TCP : parse_tcp;
            IP_PROTOCOLS_UDP : parse_udp;
            default : accept; 
        }
    }

    state parse_tcp {
        pkt.extract(hdr.tcp);
        transition accept;
    }

    state parse_udp {
        pkt.extract(hdr.udp);
        transition accept;
    }
}

control SwitchIngressDeparser(
        packet_out pkt,
        inout header_t hdr,
        in ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md) {

    Mirror() mirror;
    Checksum() ipv4_checksum;

    apply {
        if (ig_intr_dprsr_md.mirror_type == MIRROR_TYPE_I2E) {
            // The mirror_h header provided as the second argument to emit()
            // will become the first header on the mirrored packet.
            // The egress parser will check for that header
            mirror.emit<mirror_h>(ig_md.mirror_session, 
                                  {ig_md.mirror_bmd_type, ig_md.afd.vlink_id});
        }

        hdr.ipv4.hdr_checksum = ipv4_checksum.update(
            {hdr.ipv4.version,
            hdr.ipv4.ihl,
            hdr.ipv4.dscp,
            hdr.ipv4.ecn,
            hdr.ipv4.total_len,
            hdr.ipv4.identification,
            hdr.ipv4.flags,
            hdr.ipv4.frag_offset,
            hdr.ipv4.ttl,
            hdr.ipv4.protocol,
            hdr.ipv4.src_addr,
            hdr.ipv4.dst_addr});

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
        mirror_h common_md = pkt.lookahead<mirror_h>();
        transition select(common_md.bmd_type) {
            BMD_TYPE_MIRROR : parse_mirror_md;
            BMD_TYPE_I2E    : parse_bridged_md;
            default : accept;
        }
    }
    
    state parse_mirror_md {
        mirror_h mirror_md;
        pkt.extract(mirror_md);
        eg_md.afd.setValid();
        eg_md.afd.is_worker = 1;
        // Move mirrored header fields to their expected locations.
        eg_md.afd.bmd_type = mirror_md.bmd_type;
        eg_md.afd.vlink_id = mirror_md.vlink_id;
        
        transition parse_ethernet;
    }

    state parse_bridged_md {
        pkt.extract(eg_md.afd);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select (hdr.ethernet.ether_type) {
            ETHERTYPE_IPV4 : parse_ipv4;
            default : reject;
        }
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTOCOLS_TCP : parse_tcp;
            IP_PROTOCOLS_UDP : parse_udp;
            default : accept;
        }
    }

    state parse_tcp {
        pkt.extract(hdr.tcp);
        transition accept;
    }

    state parse_udp {
        pkt.extract(hdr.udp);
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
        pkt.emit(hdr.afd_update);  // header contains update values
	// Normal headers
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4);
        pkt.emit(hdr.tcp);
        pkt.emit(hdr.udp);
    }
}
