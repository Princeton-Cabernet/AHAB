/*
    AHAB project
    Copyright (c) 2022, Robert MacDavid, Xiaoqi Chen, Princeton University.
    macdavid [at] cs.princeton.edu
    License: AGPLv3
*/

#include "define.h"

// Accurately track real and hypothetical link rate, count non-dropped packets
control ByteDumps(in vlink_index_t vlink_id,
                  in bytecount_t scaled_pkt_len,
                  in bit<1> drop_flag_lo,
                  in bit<1> drop_flag_mid,
                  in bit<1> drop_flag_hi,
                  out bytecount_t pkt_len_lo,
                  out bytecount_t pkt_len_hi,
                  out bytecount_t pkt_len_all) {


    /* --------------------------------------------------------------------------------------
     * If this packet is going to actually be dropped, but threshold_lo or threshold_hi wouldn't have dropped it,
     * add the bytes of this packet to a per-slice byte store. The next non-dropped packet will pick up the bytes
     * and carry them to the egress rate estimators.
     * -------------------------------------------------------------------------------------- */

    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) byte_store_lo;
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_lo) combine_lo_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes + scaled_pkt_len;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_lo) grab_lo_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_lo) dump_lo_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            dumped_bytes = dumped_bytes + scaled_pkt_len;
            bytes_sent = 0;
        }
    };
    action combine_lo_bytes() {
        pkt_len_lo = combine_lo_bytes_regact.execute(vlink_id);
    }
    action grab_lo_bytes() {
        pkt_len_lo = grab_lo_bytes_regact.execute(vlink_id);
    }
    action dump_lo_bytes() {
        pkt_len_lo = dump_lo_bytes_regact.execute(vlink_id);
    }
    action nop_lo(){
        pkt_len_lo = 0;
    }

    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) byte_store_hi;
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_hi) combine_hi_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes + scaled_pkt_len;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_hi) grab_hi_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_hi) dump_hi_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            dumped_bytes = dumped_bytes + scaled_pkt_len;
            bytes_sent = 0;
        }
    };
    action combine_hi_bytes() {
        pkt_len_hi = combine_hi_bytes_regact.execute(vlink_id);
    }
    action grab_hi_bytes() {
        pkt_len_hi = grab_hi_bytes_regact.execute(vlink_id);
    }
    action dump_hi_bytes() {
        pkt_len_hi = dump_hi_bytes_regact.execute(vlink_id);
    }
    action nop_hi(){
        pkt_len_hi = 0;
    }


    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) byte_store_all;
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_all) grab_all_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            bytes_sent = dumped_bytes + scaled_pkt_len;
            dumped_bytes = 0;
        }
    };
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(byte_store_all) dump_all_bytes_regact = {
        void apply(inout bytecount_t dumped_bytes, out bytecount_t bytes_sent) {
            dumped_bytes = dumped_bytes + scaled_pkt_len;
            bytes_sent = 0;
        }
    };

    action grab_all_bytes() {
        pkt_len_all = grab_all_bytes_regact.execute(vlink_id);
    }
    action dump_all_bytes() {
        pkt_len_all = dump_all_bytes_regact.execute(vlink_id);
    }

	apply {
        if(drop_flag_mid==0){
            grab_all_bytes();

            if(drop_flag_lo==0){
                combine_lo_bytes();
            }else{
                grab_lo_bytes();
            }

            if(drop_flag_hi==0){
                combine_hi_bytes();
            }else{
                grab_hi_bytes();
            }
        }else{
            dump_all_bytes();

            if(drop_flag_lo==0){
                dump_lo_bytes();
            }else{
                nop_lo();
            }

            if(drop_flag_hi==0){
                dump_hi_bytes();
            }else{
                nop_hi();
            }
        }
	}
}
