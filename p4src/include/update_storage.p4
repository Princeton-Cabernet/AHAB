// Approx UPF. Copyright (c) Princeton University, all rights reserved



control UpdateStorage(in vlink_index_t vlink_id,
                        in byterate_t vlink_demand,
                        in byterate_t vlink_capacity,
                        in byterate_t max_rate,
                        inout byterate_t new_threshold,
                        in bit<1> is_worker,
                        out bit<8> congestion_flag) {
    // Loads and saves congestion flags and freshly interpolated thresholds


    @hidden
    Register<byterate_t, vlink_index_t>(size=NUM_VLINKS) winning_thresholds;
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(winning_thresholds) grab_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            retval = stored;
        }
    };
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(winning_thresholds) dump_new_threshold_regact = {
        void apply(inout byterate_t stored) {
            stored = new_threshold;
        }
    };
    @hidden
    action grab_new_threshold() {
        new_threshold = grab_new_threshold_regact.execute(vlink_id);
    }
    @hidden
    action dump_new_threshold() {
        dump_new_threshold_regact.execute(vlink_id);
    }
    @hidden
    table dump_or_grab_new_threshold {
        key = {
            is_worker : exact;
        }
        actions = {
            dump_new_threshold;
            grab_new_threshold;
        }
        const entries = {
            0 : dump_new_threshold();
            1 : grab_new_threshold();
        }
        size = 2;
    }

    byterate_t demand_delta; 
    @hidden
    Register<bit<8>, vlink_index_t>(size=NUM_VLINKS) congestion_flags;
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) set_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag) {
	    stored_flag = 1;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) unset_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag) {
	    stored_flag = 0;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) grab_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
            returned_flag = stored_flag;
        }
    };
    @hidden
    action set_congestion_flag() {
        set_congestion_flag_regact.execute(vlink_id);
    }
    @hidden
    action unset_congestion_flag() {
        unset_congestion_flag_regact.execute(vlink_id);
    }
    @hidden
    action grab_congestion_flag() {
        congestion_flag = grab_congestion_flag_regact.execute(vlink_id);
    }
#define TERNARY_NEG_CHECK 32w0x80000000 &&& 32w0x80000000
#define TERNARY_POS_CHECK 32w0 &&& 32w0x80000000
#define TERNARY_DONT_CARE 32w0 &&& 32w0
    @hidden
    table dump_or_grab_congestion_flag {
        key = {
            is_worker : exact;
            demand_delta : ternary;
        }
        actions = {
            set_congestion_flag;
            unset_congestion_flag;
            grab_congestion_flag;
        }
        const entries = {
            (0, TERNARY_NEG_CHECK) : set_congestion_flag();
            (0, TERNARY_POS_CHECK) : unset_congestion_flag();
            (1, TERNARY_DONT_CARE) : grab_congestion_flag();
        }
        size = 3;
    }


    apply {
        demand_delta = vlink_capacity - vlink_demand; 
        // If the highest rate seen recently is lower than the new threshold, lower the threshold to that rate
        // This prevents the threshold from jumping to infinity during times of underutilization,
        // which improves convergence rate.
        // TODO: should we smooth this out?
        new_threshold = min<byterate_t>(new_threshold, max_rate);
        // If normal packet, save the new threshold. If a worker packet, load the new one
        dump_or_grab_new_threshold.apply();
        dump_or_grab_congestion_flag.apply();
    }
}
