// Approx UPF. Copyright (c) Princeton University, all rights reserved



control UpdateStorage(in vlink_index_t vlink_id,
                        in byterate_t max_rate,
                        inout byterate_t new_threshold,
                        in bit<1> is_worker,
                        out bit<1> congestion_flag) {
    // Loads and saves congestion flags and freshly interpolated thresholds


    
    Register<byterate_t, vlink_index_t>(size=NUM_VLINKS) winning_thresholds;
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(winning_thresholds) read_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            retval = stored;
        }
    };
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(winning_thresholds) write_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            stored = new_threshold;
            retval = stored;
        }
    };
    
    action read_new_threshold() {
        new_threshold = read_new_threshold_regact.execute(vlink_id);
    }
    
    action write_new_threshold() {
        new_threshold = write_new_threshold_regact.execute(vlink_id);
    }

    
    Register<bit<8>, vlink_index_t>(size=NUM_VLINKS) congestion_flags;
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) write_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> retval) {
            stored_flag = (bit<8>) congestion_flag;
            retval = stored_flag;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(congestion_flags) read_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
            returned_flag = stored_flag;
        }
    };
    
    action write_congestion_flag() {
        congestion_flag = (bit<1>) write_congestion_flag_regact.execute(vlink_id);
    }
    
    action read_congestion_flag() {
        congestion_flag = (bit<1>) read_congestion_flag_regact.execute(vlink_id);
    }


    apply {
        // If normal packet, save the new threshold. If a worker packet, load the new one
        if (is_worker == 0) {
            write_congestion_flag();
            write_new_threshold();
        } else {
            read_congestion_flag();
            read_new_threshold();
        }

        // If the highest rate seen recently is lower than the new threshold, lower the threshold to that rate
        // This prevents the threshold from jumping to infinity during times of underutilization,
        // which improves convergence rate.
        // NOTE: Only workers carry the correct max rate, so this must occur after workers laad
        new_threshold = min<byterate_t>(new_threshold, max_rate);
    }
}
