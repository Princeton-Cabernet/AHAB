/*
    AHAB project
    Copyright (c) 2022, Robert MacDavid, Xiaoqi Chen, Princeton University.
    macdavid [at] cs.princeton.edu
    License: AGPLv3
*/

// Saves and loads per-vlink state, including congestion flag and interpolated threshold for next epoch
control UpdateStorage(in bit<1> is_worker,
    inout header_t hdr,
    in byterate_t vlink_capacity, in byterate_t vlink_demand,
    in vlink_index_t vlink_id, in byterate_t new_threshold) {
    // Loads and saves congestion flags and freshly interpolated thresholds

    byterate_t capacity_minus_demand = vlink_capacity - vlink_demand;

    Register<byterate_t, vlink_index_t>(size=NUM_VLINKS) egr_reg_thresholds;
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(egr_reg_thresholds) grab_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            stored = stored;
            retval = stored;
        }
    };
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(egr_reg_thresholds) dump_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            stored = new_threshold;
            retval = stored;
        }
    };
    action grab_new_threshold() {
        hdr.afd_update.new_threshold = grab_new_threshold_regact.execute(vlink_id);
        // Finish setting the recirculation headers
        hdr.fake_ethernet.ether_type = ETHERTYPE_THRESHOLD_UPDATE;
        hdr.afd_update.vlink_id = vlink_id;
    }
    action dump_new_threshold() {
        dump_new_threshold_regact.execute(vlink_id);
        // Recirculation headers aren't needed, erase them
        hdr.fake_ethernet.setInvalid();
        hdr.afd_update.setInvalid();
    }

    table read_or_write_new_threshold {
        key = {
            is_worker : exact;
        }
        actions = {
            grab_new_threshold;
            dump_new_threshold;
        }
        const entries = {
            0 : dump_new_threshold();
            1 : grab_new_threshold();
        }
        size = 2;
    }

    Register<bit<8>, vlink_index_t>(size=NUM_VLINKS) egr_reg_flags;
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(egr_reg_flags) set_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
        stored_flag = 1;
        returned_flag = 1;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(egr_reg_flags) unset_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
        stored_flag = 0;
        returned_flag = 0;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(egr_reg_flags) grab_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
            returned_flag = stored_flag;
        }
    };
    action set_congestion_flag() {
        set_congestion_flag_regact.execute(vlink_id);
    }
    action unset_congestion_flag() {
       unset_congestion_flag_regact.execute(vlink_id);
    }
    action grab_congestion_flag() {
        hdr.afd_update.congestion_flag = (bit<1>) grab_congestion_flag_regact.execute(vlink_id);
    }
    action nop_(){}

    table read_or_write_congestion_flag {
        key = {
            is_worker : exact;
            capacity_minus_demand : ternary;
        }
        actions = {
            grab_congestion_flag;
            set_congestion_flag;
            unset_congestion_flag;
            nop_();
        }
        const entries = {
            (1, TERNARY_DONT_CARE) : grab_congestion_flag();
            (0, TERNARY_NEG_CHECK) : set_congestion_flag();
            (0, TERNARY_POS_CHECK) : unset_congestion_flag();
            (0, TERNARY_ZERO_CHECK) : unset_congestion_flag();
        }
        size = 8;
        default_action = nop_();  // Something went wrong, stick with the current fair rate threshold
    }

    apply {
        read_or_write_new_threshold.apply();
        read_or_write_congestion_flag.apply();
    }
}
