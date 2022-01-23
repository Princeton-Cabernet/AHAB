// Approx UPF. Copyright (c) Princeton University, all rights reserved
#include "define.h"

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
    @hidden
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
    @hidden
    action combine_lo_bytes() {
        pkt_len_lo = combine_lo_bytes_regact.execute(vlink_id);
    }
    @hidden
    action grab_lo_bytes() {
        pkt_len_lo = grab_lo_bytes_regact.execute(vlink_id);
    }
    @hidden
    action dump_lo_bytes() {
        dump_lo_bytes_regact.execute(vlink_id);
    }
    @hidden
    table dump_or_grab_lo_bytes {
        key = {
            drop_flag_mid : exact;
            drop_flag_lo : exact;
        }
        actions = {
            dump_lo_bytes;
            grab_lo_bytes;
            combine_lo_bytes;
        }
        const entries = {
            (1, 0) : dump_lo_bytes();
            (0, 0) : combine_lo_bytes();
            (0, 1) : grab_lo_bytes();
            // (1,1) : no_action();
        }
        size = 4;
    }
    @hidden
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
    @hidden
    action combine_hi_bytes() {
        pkt_len_hi = combine_hi_bytes_regact.execute(vlink_id);
    }
    @hidden
    action grab_hi_bytes() {
        pkt_len_hi = grab_hi_bytes_regact.execute(vlink_id);
    }
    @hidden
    action dump_hi_bytes() {
        dump_hi_bytes_regact.execute(vlink_id);
    }
    // TODO: Do we need this? Given our current method for computing drop flags,
    //       it will never be the case that mid drops but hi doesn't.
    @hidden
    table dump_or_grab_hi_bytes {
        key = {
            drop_flag_mid : exact;
            drop_flag_hi : exact;
        }
        actions = {
            dump_hi_bytes;
            grab_hi_bytes;
            combine_hi_bytes;
        }
        const entries = {
            (1, 0) : dump_hi_bytes();
            (0, 0) : combine_hi_bytes();
            (0, 1) : grab_hi_bytes();
            // (1,1) : no_action();
        }
        size = 4;
    }
    @hidden
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
    @hidden
    action grab_all_bytes() {
        pkt_len_all = grab_all_bytes_regact.execute(vlink_id);
    }
    @hidden
    action dump_all_bytes() {
        dump_all_bytes_regact.execute(vlink_id);
    }
    @hidden
    table dump_or_grab_all_bytes {
        key = {
            drop_flag_mid : exact;
        }
        actions = {
            dump_all_bytes;
            grab_all_bytes;
        }
        const entries = {
            0: grab_all_bytes();
            1 : dump_all_bytes();
        }
        size = 2;
    }


	apply {
        dump_or_grab_lo_bytes.apply();
        dump_or_grab_hi_bytes.apply();
        dump_or_grab_all_bytes.apply();
	}
}

