// Approx UPF. Copyright (c) Princeton University, all rights reserved



control UpdateStorage(in vlink_index_t vlink_id,
                        in byterate_t max_rate,
                        inout byterate_t new_threshold,
                        in bit<1> is_worker,
                        out bit<8> congestion_flag) {
    // Loads and saves congestion flags and freshly interpolated thresholds


    @hidden
    Register<byterate_t, vlink_index_t>(size=NUM_VLINKS) winning_thresholds;
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(winning_thresholds) read_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            retval = stored;
        }
    };
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(winning_thresholds) write_new_threshold_regact = {
        void apply(inout byterate_t stored) {
            stored = new_threshold;
        }
    };
    @hidden
    action read_new_threshold() {
        new_threshold = read_new_threshold_regact.execute(vlink_id);
    }
    @hidden
    action write_new_threshold() {
        write_new_threshold_regact.execute(vlink_id);
    }
    @hidden
    action read_new_threshold_default() {
        // Never executes. Silences compiler re: uninitialized metadata
        new_threshold = 0;
    }
    @hidden
    table read_or_write_new_threshold {
        key = {
            is_worker : exact;
        }
        actions = {
            write_new_threshold;
            read_new_threshold;
            read_new_threshold_default;
        }
        const entries = {
            0 : write_new_threshold();
            1 : read_new_threshold();
        }
        default_action = read_new_threshold_default();
        size = 2;
    }

    @hidden
    Register<bit<8>, vlink_index_t>(size=NUM_VLINKS) congestion_flags;
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) write_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag) {
            stored_flag = congestion_flag;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) read_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
            returned_flag = stored_flag;
        }
    };
    @hidden
    action write_congestion_flag() {
        write_congestion_flag_regact.execute(vlink_id);
    }
    @hidden
    action read_congestion_flag() {
        congestion_flag = read_congestion_flag_regact.execute(vlink_id);
    }
    @hidden
    action read_congestion_flag_default() {
        congestion_flag = 0; 
    }
    @hidden
    table read_or_write_congestion_flag {
        key = {
            is_worker : exact;
        }
        actions = {
            read_congestion_flag;
            write_congestion_flag;
            read_congestion_flag_default;
        }
        const entries = {
            1 : read_congestion_flag();
            0 : write_congestion_flag();
        }
        default_action = read_congestion_flag_default();
        size = 2;
    }


    apply {
        // If the highest rate seen recently is lower than the new threshold, lower the threshold to that rate
        // This prevents the threshold from jumping to infinity during times of underutilization,
        // which improves convergence rate.
        // TODO: should we smooth this out?
        new_threshold = min<byterate_t>(new_threshold, max_rate);
        // If normal packet, save the new threshold. If a worker packet, load the new one
        read_or_write_new_threshold.apply();
        read_or_write_congestion_flag.apply();
    }
}
