// Approx UPF. Copyright (c) Princeton University, all rights reserved

control LinkRateTracker(in vlink_index_t vlink_id, in bit<1> drop_withheld,
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

    bit<1> dummy_bit = 0;
    // Track mid threshold sending rate
    @hidden
    action rate_act() {
        vlink_rate = (byterate_t) current_rate_lpf.execute(scaled_pkt_len, vlink_id);
    }
    @hidden
    table rate_tbl {
        key = { drop_withheld : exact; }  // Only update the rate if a drop was not meant to happen
        actions = { rate_act; }
        const entries = { 1 : rate_act(); }
        size = 1;
    }
    // Track lo threshold sending rate
    @hidden
    action rate_lo_act() {
        vlink_rate_lo = (byterate_t) lo_rate_lpf.execute(scaled_pkt_len_lo, vlink_id);
    }
    @hidden
    table rate_lo_tbl {
        key = { dummy_bit : exact; }
        actions = { rate_lo_act; }
        const entries = { 0 : rate_lo_act(); }
        size = 1;
    }
    // Track hi threshold sending rate
    @hidden
    action rate_hi_act() {
        vlink_rate_hi = (byterate_t) hi_rate_lpf.execute(scaled_pkt_len_hi, vlink_id);
    }
    @hidden
    table rate_hi_tbl {
        key = { dummy_bit : exact; }
        actions = { rate_hi_act; }
        const entries = { 0 : rate_hi_act(); }
        size = 1;
    }
    // Track total demand
    @hidden
    action rate_all_act() {
        vlink_demand = total_demand_lpf.execute(scaled_pkt_len_all, vlink_id);
    }
    @hidden
    table rate_all_tbl {
        key = { dummy_bit : exact; }
        actions = { rate_all_act; }
        const entries = { 0 : rate_all_act(); }
        size = 1;
    }

    apply {
        rate_tbl.apply();
        rate_lo_tbl.apply();
        rate_hi_tbl.apply();
        rate_all_tbl.apply();
    }
}
