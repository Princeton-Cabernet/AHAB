// Approx UPF. Copyright (c) Princeton University, all rights reserved

control VLinkLookup(in header_t hdr, inout afd_metadata_t afd_md) {
    bytecount_t threshold_delta_minus = 0;

    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) stored_thresholds;
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(stored_thresholds) read_stored_threshold = {
        void apply(inout bytecount_t stored_threshold, out bytecount_t retval) {
            retval = stored_threshold;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(stored_thresholds) write_stored_threshold = {
        void apply(inout bytecount_t stored_threshold, out bytecount_t retval) {
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
            afd_md.is_worker: exact;
        }
        actions = {
            read_stored_threshold_act;
            write_stored_threshold_act;
        }
        const entries = {
            0: read_stored_threshold_act();
            1: write_stored_threshold_act();
        }
        size = 2;
    }
	action set_vlink_rshift2(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len >> 2);
	}
	action set_vlink_rshift1(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len >> 1);
	}
	action set_vlink_noshift(vlink_index_t i) {
		afd_md.vlink_id = i;
		afd_md.scaled_pkt_len=(bytecount_t) hdr.ipv4.total_len;
	}
	action set_vlink_lshift1(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 1);
	}
	action set_vlink_lshift2(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 2);
	}
	action set_vlink_lshift3(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 3);
	}
	action set_vlink_lshift4(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 4);
	}
	action set_vlink_lshift5(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 5);
	}
	action set_vlink_lshift6(vlink_index_t i){
		afd_md.vlink_id=i;
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 6);
	}
	table tb_match_ip{
		key = {
            hdr.ipv4.dst_addr: lpm;
            afd_md.is_worker : exact; // TODO: set the is_worker flag on recirculation
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
		}
		default_action = set_vlink_noshift(0);
		size = 1024;
	}


    // candidate_delta will be the largest power of 2 that is smaller than threshold/2
    // So the new lo and hi fair rate thresholds will be roughly +- 50%
    @hidden
    action lo_boundary_compute_candidates_act(bytecount_t candidate_delta, exponent_t candidate_delta_pow) {
        // At the low boundary, the low candidate equals the mid (current) candidate
        afd_md.candidate_delta     = candidate_delta;
        afd_md.candidate_delta_pow = candidate_delta_pow;
        threshold_delta_minus = 0;  // indirect due to a tofino limitation
        afd_md.threshold_hi = afd_md.threshold + candidate_delta;
    }
    @hidden
    action hi_boundary_compute_candidates_act(bytecount_t candidate_delta, exponent_t candidate_delta_pow) {
        // At the high boundary, the high candidate equals the mid (current) candidate
        afd_md.candidate_delta     = candidate_delta;
        afd_md.candidate_delta_pow = candidate_delta_pow;
        threshold_delta_minus = candidate_delta;  // indirect subtraction for tofino
        afd_md.threshold_hi = afd_md.threshold;
    }
    @hidden
    action compute_candidates_act(bytecount_t candidate_delta, exponent_t candidate_delta_pow) {
        afd_md.candidate_delta     = candidate_delta;
        afd_md.candidate_delta_pow = candidate_delta_pow;
        threshold_delta_minus = candidate_delta;  // indirect subtraction for tofino
        afd_md.threshold_hi = afd_md.threshold + candidate_delta;
    }
    @hidden
    table compute_candidates {
        key = {
            afd_md.threshold : ternary; // find the highest bit
        }
        actions = {
            lo_boundary_compute_candidates_act;
            compute_candidates_act;
            hi_boundary_compute_candidates_act;
        }
        size = 32;
        /*
        // Python code for printing const entries
        lowest = 10
        highest = 20
        for i in range(lowest, highest+1):
            act_str = "compute_candidates_act(%d, %d)" % (1 << (i-1), (i-1))
            if i == lowest:
                act_str = "lo_boundary_" + act_str
            if i == highest:
                act_str = "hi_boundary_" + act_str
            print("(0x%x &&& 0x%x): %s;" % (1 << i, (0xffffffff << i) & 0xffffffff, act_str))

        */
        // TODO: Maybe this table shouldn't be constant/hidden. 
        //       We may want to change the range of thresholds at runtime.
        const entries = {
            (0x20 &&& 0xffffffe0): lo_boundary_compute_candidates_act(16, 4);
            (0x40 &&& 0xffffffc0): compute_candidates_act(32, 5);
            (0x80 &&& 0xffffff80): compute_candidates_act(64, 6);
            (0x100 &&& 0xffffff00): compute_candidates_act(128, 7);
            (0x200 &&& 0xfffffe00): compute_candidates_act(256, 8);
            (0x400 &&& 0xfffffc00): compute_candidates_act(512, 9);
            (0x800 &&& 0xfffff800): compute_candidates_act(1024, 10);
            (0x1000 &&& 0xfffff000): compute_candidates_act(2048, 11);
            (0x2000 &&& 0xffffe000): compute_candidates_act(4096, 12);
            (0x4000 &&& 0xffffc000): compute_candidates_act(8192, 13);
            (0x8000 &&& 0xffff8000): compute_candidates_act(16384, 14);
            (0x10000 &&& 0xffff0000): compute_candidates_act(32768, 15);
            (0x20000 &&& 0xfffe0000): compute_candidates_act(65536, 16);
            (0x40000 &&& 0xfffc0000): compute_candidates_act(131072, 17);
            (0x80000 &&& 0xfff80000): compute_candidates_act(262144, 18);
            (0x100000 &&& 0xfff00000): compute_candidates_act(524288, 19);
            (0x200000 &&& 0xffe00000): compute_candidates_act(1048576, 20);
            (0x400000 &&& 0xffc00000): compute_candidates_act(2097152, 21);
            (0x800000 &&& 0xff800000): compute_candidates_act(4194304, 22);
            (0x1000000 &&& 0xff000000): hi_boundary_compute_candidates_act(8388608, 23);
        }
    }

    int<1> dummy = 0;
    @hidden
    action indirect_sub_act() {
            afd_md.threshold_lo = afd_md.threshold - threshold_delta_minus;
    }
    @hidden
    table indirect_sub_tbl {
        key = {
            dummy: exact;
        }
        actions = {
            indirect_sub_act;
        }
        const entries = {
            0 : indirect_sub_act();
        }
        default_action = indirect_sub_act();
        size = 1;
    }


	apply {
		tb_match_ip.apply();
        read_or_write_threshold.apply();
		compute_candidates.apply();
		indirect_sub_tbl.apply();
	}
}
