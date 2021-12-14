// Approx UPF. Copyright (c) Princeton University, all rights reserved


control MaxRateEstimator(in vlink_index_t vlink_id,
                         in byterate_t curr_rate,
                         in bit<1> new_epoch,
                         out byterate_t max_rate) {


    Register<rate_epoch_pair_t, vlink_index_t>(NUM_VLINKS) window_maxrate;



    RegisterAction<byterate_t, vlink_index_t, byterate_t>(windowd_maxrate) write_maxrate_regact = {
        void apply(inout byterate_t stored_rate) {
            if (stored_rate < curr_rate) {
                stored_rate = curr_rate;
            }
        }
    }
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(windowd_maxrate) write_maxrate_regact = {
        void apply(inout byterate_t stored_rate, out byterate_t returned_rate) {
            returned_rate = stored_rate;
            stored_rate = 0;
        }
    }

    @hidden
    action read_maxrate() {
        max_rate = read_maxrate_regact.execute(vlink_id);
    }
    @hidden
    action write_maxrate() {
        write_maxrate_regact.execute(vlink_id);
    }

    @hidden
    table read_or_write_maxrate {
        key = {
            new_epoch : exact;
        }
        actions = {
            read_maxrate;
            write_maxrate;
        }
        const entries = {
            0 : write_maxrate();
            1 : read_maxrate();
        }
    }

    apply {
        read_or_write_maxrate.apply();
    }
}
