// Approx UPF. Copyright (c) Princeton University, all rights reserved

control VLinkLookup(in header_t hdr, inout afd_metadata_t afd_md,
                    out bit<9> ucast_egress_port, out bit<3> drop_ctl) {
    Register<bit<8>, vlink_index_t>(size=NUM_VLINKS) congestion_flags;
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) write_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag) {
            stored_flag = afd_md.congestion_flag;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) read_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
            returned_flag = stored_flag;
        }
    };
    action write_congestion_flag() {
        write_congestion_flag_regact.execute(afd_md.vlink_id);
    }
    action read_congestion_flag() {
        afd_md.congestion_flag = read_congestion_flag_regact.execute(afd_md.vlink_id);
    }

    Register<byterate_t, vlink_index_t>(NUM_VLINKS) stored_thresholds;
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(stored_thresholds) read_stored_threshold = {
        void apply(inout byterate_t stored_threshold, out byterate_t retval) {
            if (stored_threshold == 0) {
                stored_threshold = DEFAULT_THRESHOLD;
            }
            retval = stored_threshold;
        }
    };
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(stored_thresholds) write_stored_threshold = {
        void apply(inout byterate_t stored_threshold) {
            stored_threshold = afd_md.new_threshold;
        }
    };
    action read_stored_threshold_act() {
        afd_md.threshold = read_stored_threshold.execute(afd_md.vlink_id);
    }
    action write_stored_threshold_act() {
        write_stored_threshold.execute(afd_md.vlink_id);
    }

	action set_vlink_default() {
		afd_md.vlink_id = (vlink_index_t) hdr.ipv4.dst_addr[8:0];
		afd_md.scaled_pkt_len=(bytecount_t) hdr.ipv4.total_len;
                ucast_egress_port = hdr.ipv4.dst_addr[8:0];
	}
	action set_vlink_rshift2(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len >> 2);
		ucast_egress_port = i[8:0];
	}
	action set_vlink_rshift1(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len >> 1);
		ucast_egress_port = i[8:0];
	}
	action set_vlink_noshift(vlink_index_t i) {
		afd_md.vlink_id = i;
		afd_md.scaled_pkt_len=(bytecount_t) hdr.ipv4.total_len;
		ucast_egress_port = i[8:0];
	}
	action set_vlink_lshift1(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 1);
		ucast_egress_port = i[8:0];
	}
	action set_vlink_lshift2(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 2);
		ucast_egress_port = i[8:0];
	}
	action set_vlink_lshift3(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 3);
		ucast_egress_port = i[8:0];
	}
	action set_vlink_lshift4(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 4);
		ucast_egress_port = i[8:0];
	}
	action set_vlink_lshift5(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 5);
		ucast_egress_port = i[8:0];
	}
	action set_vlink_lshift6(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 6);
		ucast_egress_port = i[8:0];
	}
	table tb_match_ip{
        key = {
            hdr.ipv4.dst_addr: lpm;
        }
        actions = {
            set_vlink_rshift2;
            set_vlink_rshift1;
            set_vlink_noshift;
            set_vlink_lshift1;
            set_vlink_lshift2;
            set_vlink_lshift3;
            set_vlink_lshift4;
            set_vlink_lshift5;
            set_vlink_lshift6;
            set_vlink_default;
        }
        default_action = set_vlink_default();
        size = 1024;
    }


    // candidate_delta will be the largest power of 2 that is smaller than threshold/2
    // So the new lo and hi fair rate thresholds will be roughly +- 50%
    action compute_candidates_act(byterate_t candidate_delta, byterate_t candidate_delta_negative, exponent_t candidate_delta_pow) {
        afd_md.candidate_delta     = candidate_delta;
        afd_md.candidate_delta_pow = candidate_delta_pow;

        afd_md.threshold_hi = afd_md.threshold + candidate_delta;
        afd_md.threshold_lo = afd_md.threshold + candidate_delta_negative;
    }
    table compute_candidates {
        key = {
            afd_md.threshold : ternary; // find the highest bit
        }
        actions = {
            compute_candidates_act;
        }
        size = 32;
    }

    apply {
        if (!hdr.afd_update.isValid()) {
            tb_match_ip.apply();
            read_congestion_flag();
            read_stored_threshold_act();
            compute_candidates.apply();
            drop_ctl = 0;
        }else{
            write_congestion_flag();
            write_stored_threshold_act();
            drop_ctl = 1;
            exit;
        }
    }
}
