// Approx UPF. Copyright (c) Princeton University, all rights reserved

control LinkRateTracker(in vlink_index_t vlink_id, 
                        in bytecount_t scaled_pkt_len, in bytecount_t scaled_pkt_len_all,
                        in bytecount_t scaled_pkt_len_lo, in bytecount_t scaled_pkt_len_hi,
                        out byterate_t vlink_rate, out byterate_t vlink_rate_lo, out byterate_t vlink_rate_hi,
                        out byterate_t vlink_demand) {

    // current_rate_lpf is the true transmitted bitrate
    // lo_ and hi_ are bitrates achieved by simulating lower and higher drop rates
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) current_rate_lpf;
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) lo_rate_lpf;
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) hi_rate_lpf;

    // Per-vlink total demand (aka arrival rate)
    // Only read by the control plane and used to compute vtrunk_fair_rate
    Lpf<bytecount_t, vlink_index_t>(size=NUM_VLINKS) total_demand_lpf;

    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) stored_vlink_demands;


    action rate_act() {
        vlink_rate = (byterate_t) current_rate_lpf.execute(scaled_pkt_len, vlink_id);
    }
    action rate_lo_act() {
        vlink_rate_lo = (byterate_t) lo_rate_lpf.execute(scaled_pkt_len_lo, vlink_id);
    }
    action rate_hi_act() {
        vlink_rate_hi = (byterate_t) hi_rate_lpf.execute(scaled_pkt_len_hi, vlink_id);
    }
    action rate_all_act() {
        vlink_demand = total_demand_lpf.execute(scaled_pkt_len_all, vlink_id);
    }
    action store_vlink_demand() {
        stored_vlink_demands.write(vlink_id, vlink_demand);
    }
    

    apply {
        rate_act();
        rate_lo_act();
        rate_hi_act();
        rate_all_act();
        store_vlink_demand();
    }
}
