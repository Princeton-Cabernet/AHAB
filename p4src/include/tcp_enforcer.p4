// Approx UPF. Copyright (c) Princeton University, all rights reserved
#include "define.h"


control TcpEnforcer(in byterate_t measured_rate,
                     in bit<16> pkt_len,
                     in byterate_t threshold_lo,
                     in byterate_t threshold_mid,
                     in byterate_t threshold_hi,
                      in bit<32> src_ip,
                      in bit<32> dst_ip,
                      in bit<8> proto,
                      in bit<16> src_port,
                      in bit<16> dst_port,
                     out bit<1> drop_flag,
                     out bit<1> ecn_flag) {
    
    // difference (candidate - measured_rate) for each candidate
    byterate_t dthresh_lo = 0;
    byterate_t dthresh_mid = 0;
    byterate_t dthresh_hi = 0;

    bit<16> scaled_down_pktlen; // input to the "count_til_*" registers
    bit<16> scaled_down_pktlen_lo; // input if lo is exceeded but mid is not
    bit<16> scaled_down_pktlen_mid; // input if mid is exceeded

    bit<1> mid_exceeded_flag;
    

    Register<bit<16>, cms_index_t>(size=CMS_HEIGHT) count_til_drop_reg;
    Register<bit<16>, cms_index_t>(size=CMS_HEIGHT) count_til_ecn_reg;

    RegisterAction<bit<16>, cms_index_t, bit<1>>(count_til_drop_reg) update_count_til_drop = {
        void apply(inout bit<16> stored, out bit<1> returned) {
            if (stored < scaled_down_pktlen) {
                stored = 37500;  // 400 * 1500 (MTU) divided by 16.
                returned = mid_exceeded_flag;
            } else {
                stored = stored - scaled_down_pktlen;
                returned = 0;
            }
        }
    };
    RegisterAction<bit<16>, cms_index_t, bit<1>>(count_til_ecn_reg) update_count_til_ecn = {
        void apply(inout bit<16> stored, out bit<1> returned) {
            if (stored < scaled_down_pktlen) {
                stored = 3750;  // 40*1500 (MTU) divided by 16
                returned = mid_exceeded_flag;
            } else {
                stored = stored - scaled_down_pktlen;
                returned = 0;
            }
        }
    };

    

    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_1;
    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_2;


// width of this key and mask should equal sizeof(byterate_t)
#define TERNARY_NEG_CHECK 32w0x80000000 &&& 32w0x80000000
#define TERNARY_NONNEG_CHECK 32w0 &&& 32w0x80000000
#define TERNARY_DONT_CARE 32w0 &&& 32w0
    action set_neither_exceeded() {
        scaled_down_pktlen = 0;
        mid_exceeded_flag = 0;
    }
    action set_lo_exceeded() { 
        scaled_down_pktlen = scaled_down_pktlen_lo;
        mid_exceeded_flag = 0;
    }
    action set_mid_exceeded() {
        scaled_down_pktlen = scaled_down_pktlen_mid;
        mid_exceeded_flag = 1;
    }
    table check_candidates_exceeded { 
        key = {
            dthresh_lo  : ternary; // negative if threshold_lo exceeded
            dthresh_mid : ternary; // negative if threshold_mid exceeded
        }
        actions = {
            set_neither_exceeded;
            set_lo_exceeded;
            set_mid_exceeded;
        }
        size = 4;
        const entries = {
            (TERNARY_NEG_CHECK, TERNARY_NONNEG_CHECK) : set_lo_exceeded();
            (TERNARY_DONT_CARE, TERNARY_NEG_CHECK) : set_mid_exceeded();
        }
        default_action = set_neither_exceeded();
    }

    action calculate_threshold_differences_act() {
        dthresh_lo  = threshold_lo - measured_rate;
        dthresh_mid = threshold_mid - measured_rate;
        dthresh_hi  = threshold_hi - measured_rate;
    }
    table calculate_threshold_differences_tbl {
        key = {}
        actions = {
            calculate_threshold_differences_act;
        }
        size = 1;
        default_action = calculate_threshold_differences_act;
    }

    action scale_down_pktlens_act() {
        scaled_down_pktlen_mid = pkt_len >> 4;  // divide by 16
        scaled_down_pktlen_lo = pkt_len >> 5; // divide by 32
    }
    table scale_down_pktlens_tbl {
        key = {}
        actions = { scale_down_pktlens_act; }
        size = 1;
        default_action = scale_down_pktlens_act();
    }
    action correct_pktlens_act() {
        scaled_down_pktlen_lo = max<bit<16>>(1, scaled_down_pktlen_lo);  // make sure its still nonzero
        scaled_down_pktlen_mid = max<bit<16>>(1, scaled_down_pktlen_mid);  // make sure its still nonzero
    }
    table correct_pktlens_tbl {
        key = {}
        actions = { correct_pktlens_act; }
        size = 1;
        default_action = correct_pktlens_act();
    }
        

    apply {
        scale_down_pktlens_tbl.apply();
        correct_pktlens_tbl.apply();

        // Check if each of the threshold candidates were exceeded.
        calculate_threshold_differences_tbl.apply();
        check_candidates_exceeded.apply();

        drop_flag = (bit<1>) update_count_til_drop.execute(hash_1.get({ src_ip,
                                                            dst_ip,
                                                            proto,
                                                            src_port,
                                                            dst_port}));
        ecn_flag = (bit<1>) update_count_til_ecn.execute(hash_2.get({ src_ip,
                                                            dst_ip,
                                                            proto,
                                                            src_port,
                                                            dst_port}));

	}
}

