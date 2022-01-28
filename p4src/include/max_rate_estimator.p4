// Approx UPF. Copyright (c) Princeton University, all rights reserved


control MaxRateEstimator(in vlink_index_t vlink_id,
                         in byterate_t curr_rate,
                         in bit<1> is_worker,
                         out byterate_t max_rate) {


    Register<byterate_t, vlink_index_t>(NUM_VLINKS) window_maxrate;



    RegisterAction<byterate_t, vlink_index_t, byterate_t>(window_maxrate) write_maxrate_regact = {
        void apply(inout byterate_t stored_rate, out byterate_t retval) {
            if (stored_rate < curr_rate) {
                stored_rate = curr_rate;
            }
            retval = stored_rate;
        }
    };
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(window_maxrate) read_maxrate_regact = {
        void apply(inout byterate_t stored_rate, out byterate_t returned_rate) {
            returned_rate = stored_rate;
            stored_rate = 0;
        }
    };

    @hidden
    action read_maxrate() {
        max_rate = read_maxrate_regact.execute(vlink_id);
    }
    @hidden
    action write_maxrate() {
        max_rate = write_maxrate_regact.execute(vlink_id);
    }

    apply {
        if (is_worker == 1) {
            read_maxrate();
        } else {
            write_maxrate();
        }
    }
}
