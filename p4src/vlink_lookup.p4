// Approx UPF. Copyright (c) Princeton University, all rights reserved

control VLinkLookup(in header_t hdr, inout afd_metadata_t afd_md){
    // Load vlink ID + threshold - stage1
    // Load threshold delta exponent - stage2

    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) stored_fair_rates;
    RegisterAction<bytecount_t, bytecount_t, vlink_index_t>(stored_fair_rates) read_stored_fair_rate = {
        void apply(inout bytecount_t stored_fair_rate, out bytecount_t retval) {
            retval = stored_fair_rate;
        }
    }
    RegisterAction<bytecount_t, bytecount_t, vlink_index_t>(stored_fair_rates) write_stored_fair_rate = {
        void apply(inout bytecount_t stored_fair_rate, out bytecount_t retval) {
            stored_fair_rate = afd_md.new_threshold;
        }
    }

	action set_vlink_rshift2(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len >> 2);
	}
	action set_vlink_rshift1(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len >> 1);
	}
	action set_vlink_noshift(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) hdr.ipv4.total_len;
	}
	action set_vlink_lshift1(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 1);
	}
	action set_vlink_lshift2(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 2);
	}
	action set_vlink_lshift3(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 3);
	}
	action set_vlink_lshift4(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 4);
	}
	action set_vlink_lshift5(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 5);
	}
	action set_vlink_lshift6(vlink_index_t i){
		afd_md.vlink_id=i;
        afd_md.threshold = read_stored_fair_rate.execute(i);
		afd_md.scaled_pkt_len=(bytecount_t) (hdr.ipv4.total_len << 6);
	}
    action overwrite_threshold() {
        write_stored_fair_rate.execute(afd_md.recird.vlink_id);
    }
	table tb_match_ip{
		key = {
            hdr.ipv4.dst_addr: lpm;
            afd_recirc_header.isValid() : exact; // TODO: this header name is a placeholder
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
            overwrite_threshold;
		}
		default_action = set_vlink_default();
		size = 1024;
	}


    // candidate_delta will be the largest power of 2 that is smaller than threshold/2
    // So the new lo and hi fair rate thresholds will be roughly +- 50%
    action lo_boundary_compute_candidates_act(bytecount_t candidate_delta, exponent_t candidate_delta_pow) {
        // At the low boundary, the low candidate equals the mid (current) candidate
        afd_md.candidate_delta     = candidate_delta;
        afd_md.candidate_delta_pow = candidate_delta_pow;
        afd_md.threshold_lo        = afd_md.threeshold;
        afd_md.threshold_hi        = afd_md.threshold + candidate_delta;
    }
    action hi_boundary_compute_candidates_act(bytecount_t candidate_delta, exponent_t candidate_delta_pow) {
        // At the high boundary, the high candidate equals the mid (current) candidate
        afd_md.candidate_delta     = candidate_delta;
        afd_md.candidate_delta_pow = candidate_delta_pow;
        afd_md.threshold_lo        = afd_md.threshold - candidate_delta;
        afd_md.threshold_hi        = afd_md.threshold;
    }
    action compute_candidates_act(bytecount_t candidate_delta, exponent_t candidate_delta_pow) {
        afd_md.candidate_delta     = candidate_delta;
        afd_md.candidate_delta_pow = candidate_delta_pow;
        afd_md.threshold_lo        = afd_md.threshold - candidate_delta;
        afd_md.threshold_hi        = afd_md.threshold + candidate_delta;
    }
    table compute_candidates {
        key = {
            afd_md.threshold : ternary; // find the highest bit
        }
        actions = {
            lo_boundary_compute_candidates_act;
            compute_candidates_act;
            hi_boundary_compute_candidates_act;
        }
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


	apply {
		tb_match_ip.apply();
        compute_candidates.apply();
	}
}
