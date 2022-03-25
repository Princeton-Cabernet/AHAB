// Approx UPF. Copyright (c) Princeton University, all rights reserved
#include "define.h"


control TcpEnforcer(in byterate_t measured_rate,
                     in bit<16> pkt_len,
                     in byterate_t threshold_lo,//ignored, always 0.5x
                     in byterate_t threshold_mid,
                     in byterate_t threshold_hi,//ignored, always 1.5x
                      in bit<32> src_ip,
                      in bit<32> dst_ip,
                      in bit<8> proto,
                      in bit<16> src_port,
                      in bit<16> dst_port,
                     out bit<1> drop_flag_lo,
                     out bit<1> drop_flag_mid,
                     out bit<1> drop_flag_hi,
                     out bit<8> ecn_flag) {
    
    byterate_t threshold_lo_50;//0.5x
    action calc_thres_offset_step0(){
        threshold_lo_50 = threshold_mid >> 1;
    }
    byterate_t threshold_hi_50;//1.5x
    action calc_thres_offset_step1(){
        threshold_hi_50 = threshold_mid+threshold_lo_50;
    }
    // difference (candidate - measured_rate) for each candidate
    byterate_t dthresh_lo;
    byterate_t dthresh_mid;
    byterate_t dthresh_hi;
    action calc_thres_offset_step2(){
        dthresh_lo = threshold_lo_50 - measured_rate;
        dthresh_mid = threshold_mid - measured_rate;
        dthresh_hi = threshold_hi_50 - measured_rate;
    }

    bit<32> scaled_down_pktlen = (bit<32>) pkt_len; // input to the "count_til_*" registers
    bit<32> drop_reset_val = threshold_mid << 5; // T*32
    bit<32> ecn_reset_val = threshold_mid << 3; //T*8

    bit<8> low_exceeded_flag = 0;
    bit<8> mid_exceeded_flag = 0;
    bit<8> hi_exceeded_flag = 0;

// width of this key and mask should equal sizeof(byterate_t)
#define TERNARY_NEG_CHECK 32w0x80000000 &&& 32w0x80000000
#define TERNARY_NONNEG_CHECK 32w0 &&& 32w0x80000000
#define TERNARY_DONT_CARE 32w0 &&& 32w0
    action set_neither_exceeded() {
        low_exceeded_flag = 0;
        mid_exceeded_flag = 0;
        hi_exceeded_flag  = 0;

        scaled_down_pktlen=0;
    }
    action set_lo_exceeded() { 
        low_exceeded_flag = 1;
        mid_exceeded_flag = 0;
        hi_exceeded_flag  = 0;

        scaled_down_pktlen = scaled_down_pktlen >> 2; // slow clear
    }
    action set_mid_exceeded() {
        low_exceeded_flag = 1;
        mid_exceeded_flag = 1;
        hi_exceeded_flag  = 0;
    }
    action set_hi_exceeded() {
        low_exceeded_flag = 1;
        mid_exceeded_flag = 1;
        hi_exceeded_flag  = 1;

        drop_reset_val = 0;
        ecn_reset_val = 0;
    }
    table check_candidates_exceeded { 
        key = {
            dthresh_lo  : ternary; // negative if threshold_lo exceeded
            dthresh_mid : ternary; // negative if threshold_mid exceeded
            dthresh_hi : ternary; // negative if threshold_mid exceeded
        }
        actions = {
            set_neither_exceeded;
            set_lo_exceeded;
            set_mid_exceeded;
            set_hi_exceeded;
        }
        size = 4;
        const entries = {
            (TERNARY_NONNEG_CHECK, TERNARY_NONNEG_CHECK, TERNARY_NONNEG_CHECK) : set_neither_exceeded();
            (TERNARY_NEG_CHECK, TERNARY_NONNEG_CHECK, TERNARY_NONNEG_CHECK) : set_lo_exceeded();
            (TERNARY_NEG_CHECK, TERNARY_NEG_CHECK, TERNARY_NONNEG_CHECK) : set_mid_exceeded();
            (TERNARY_NEG_CHECK, TERNARY_NEG_CHECK, TERNARY_NEG_CHECK) : set_hi_exceeded();
        }
        default_action = set_neither_exceeded();
    }

    Register<bit<32>, cms_index_t>(size=CMS_HEIGHT) count_til_drop_reg;
    Register<bit<32>, cms_index_t>(size=CMS_HEIGHT) count_til_ecn_reg;

    RegisterAction<bit<32>, cms_index_t, bit<8>>(count_til_drop_reg) countdown_drop = {
        void apply(inout bit<32> stored, out bit<8> returned) {
            if (stored < scaled_down_pktlen) {
                stored = drop_reset_val;
                returned = 1;
            } else {
                stored = stored - scaled_down_pktlen;
                returned = 0;
            }
        }
    };
    RegisterAction<bit<32>, cms_index_t, bit<8>>(count_til_drop_reg) countdown_nodrop = {
        void apply(inout bit<32> stored, out bit<8> returned) {
            if (stored < scaled_down_pktlen) {
                stored = 0;
                returned = 0;
            } else {
                stored = stored - scaled_down_pktlen;
                returned = 0;
            }
        }
    };

    RegisterAction<bit<32>, cms_index_t, bit<8>>(count_til_ecn_reg) countdown_ecn = {
        void apply(inout bit<32> stored, out bit<8> returned) {
            if (stored < scaled_down_pktlen) {
                stored = ecn_reset_val;
                returned = 1;
            } else {
                stored = stored - scaled_down_pktlen;
                returned = 0;
            }
        }
    };
    RegisterAction<bit<32>, cms_index_t, bit<8>>(count_til_ecn_reg) countdown_noecn = {
        void apply(inout bit<32> stored, out bit<8> returned) {
            if (stored < scaled_down_pktlen) {
                stored = 0;
                returned = 0;
            } else {
                stored = stored - scaled_down_pktlen;
                returned = 0;
            }
        }
    };
    
    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_1;

    apply {
        calc_thres_offset_step0();
        calc_thres_offset_step1();
        calc_thres_offset_step2();
        check_candidates_exceeded.apply();

        cms_index_t reg_index=hash_1.get({  src_ip,
                                dst_ip,
                                proto,
                                src_port,
                                dst_port});
        if(mid_exceeded_flag==1){
            drop_flag_mid= (bit<1>) countdown_drop.execute(reg_index);
            ecn_flag = countdown_ecn.execute(reg_index);
        }else{
            drop_flag_mid= (bit<1>) countdown_nodrop.execute(reg_index);
            ecn_flag = countdown_noecn.execute(reg_index);
        }
        drop_flag_lo=drop_flag_mid;
        if(hi_exceeded_flag==1){
            drop_flag_hi=drop_flag_mid;
        }else{
            drop_flag_hi=0;   
        }
    }
}
