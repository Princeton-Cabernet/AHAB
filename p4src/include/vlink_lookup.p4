// Approx UPF. Copyright (c) Princeton University, all rights reserved

control VLinkLookup(in header_t hdr, inout afd_metadata_t afd_md,
                    out bit<9> ucast_egress_port, out bit<3> drop_ctl) {
    @hidden
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
    @hidden
    action write_congestion_flag() {
        write_congestion_flag_regact.execute(afd_md.vlink_id);
    }
    @hidden
    action read_congestion_flag() {
        afd_md.congestion_flag = read_congestion_flag_regact.execute(afd_md.vlink_id);
    }

    @hidden
    table read_or_write_congestion_flag {
        key = {
	    hdr.afd_update.isValid() : exact;
        }
        actions = {
            write_congestion_flag;
            read_congestion_flag;
        }
        const entries = {
            true : write_congestion_flag();
            false : read_congestion_flag();
        }
        size = 2;
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
    @hidden
    action read_stored_threshold_act() {
        afd_md.threshold = read_stored_threshold.execute(afd_md.vlink_id);
    }
    @hidden
    action write_stored_threshold_act() {
        write_stored_threshold.execute(afd_md.vlink_id);
    }
    @hidden
    table read_or_write_threshold {
        key = {
            hdr.afd_update.isValid() : exact;
        }
        actions = {
            read_stored_threshold_act;
            write_stored_threshold_act;
        }
        const entries = {
            true: read_stored_threshold_act();
            false: write_stored_threshold_act();
        }
        size = 2;
    }
	action set_vlink_default() {
		afd_md.vlink_id = 0;
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
    @hidden
    action compute_candidates_act(byterate_t candidate_delta, byterate_t candidate_delta_negative, exponent_t candidate_delta_pow) {
        afd_md.candidate_delta     = candidate_delta;
        afd_md.candidate_delta_pow = candidate_delta_pow;

        afd_md.threshold_hi = afd_md.threshold + candidate_delta;
	afd_md.threshold_lo = afd_md.threshold + candidate_delta_negative;
    }
    @hidden
    table compute_candidates {
        key = {
            afd_md.threshold : ternary; // find the highest bit
        }
        actions = {
            compute_candidates_act;
        }
        size = 32;
        /*
        // Python code for printing const entries
        lowest = 10
        highest = 20
        for i in range(lowest, highest+1):
            pos_delta=(1 << (i-1) )
            neg_delta=-pos_delta 
            if i == lowest:
                neg_delta=0
            if i == highest:
                pos_delta=0;
            act_str = "compute_candidates_act(%d, %d, %d)" % (pos_delta, neg_deltf Truea, (i-1))
            print("(0x%x &&& 0x%x): %s;" % (1 << i, (0xffffffff << i) & 0xffffffff, act_str))

        */
        // TODO: Maybe this table shouldn't be constant/hidden. 
        //       We may want to change the range of thresholds at runtime.
        const entries = {
            (0x20 &&& 0xffffffe0): compute_candidates_act(16, 0 ,4);
            (0x40 &&& 0xffffffc0): compute_candidates_act(32, -32, 5);
            (0x80 &&& 0xffffff80): compute_candidates_act(64, -64, 6);
            (0x100 &&& 0xffffff00): compute_candidates_act(128, -128, 7);
            (0x200 &&& 0xfffffe00): compute_candidates_act(256, -256, 8);
            (0x400 &&& 0xfffffc00): compute_candidates_act(512, -512, 9);
            (0x800 &&& 0xfffff800): compute_candidates_act(1024, -1024, 10);
            (0x1000 &&& 0xfffff000): compute_candidates_act(2048, -2048, 11);
            (0x2000 &&& 0xffffe000): compute_candidates_act(4096, -4096, 12);
            (0x4000 &&& 0xffffc000): compute_candidates_act(8192, -8192, 13);
            (0x8000 &&& 0xffff8000): compute_candidates_act(16384, -16384, 14);
            (0x10000 &&& 0xffff0000): compute_candidates_act(32768, -32768, 15);
            (0x20000 &&& 0xfffe0000): compute_candidates_act(65536, -65536, 16);
            (0x40000 &&& 0xfffc0000): compute_candidates_act(131072, -131072,17);
            (0x80000 &&& 0xfff80000): compute_candidates_act(262144, -262144,18);
            (0x100000 &&& 0xfff00000): compute_candidates_act(524288, -524288,19);
            (0x200000 &&& 0xffe00000): compute_candidates_act(1048576, -1048576,20);
            (0x400000 &&& 0xffc00000): compute_candidates_act(2097152, -2097152,21);
            (0x800000 &&& 0xff800000): compute_candidates_act(4194304, -4194304,22);
            (0x1000000 &&& 0xff000000): compute_candidates_act(0,-8388608, 23);
        }
    }

    apply {
        if (!hdr.afd_update.isValid()) {
            tb_match_ip.apply();
	}

        read_or_write_congestion_flag.apply();
        read_or_write_threshold.apply();

        if (hdr.afd_update.isValid()) {
	    // A recirculated packet's only job is to write a new threshold,
            // which just happened in those previous two tables, so time to drop.
            drop_ctl = 1;
            exit;
        } else {
            compute_candidates.apply();
        }
    }
}
