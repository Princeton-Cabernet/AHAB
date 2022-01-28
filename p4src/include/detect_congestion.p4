control DetectCongestion(in byterate_t vlink_capacity,
                         in byterate_t vlink_demand,
                         out bit<1> congestion_flag) {

    byterate_t demand_delta;
    @hidden
    action set_congestion_flag_act(bit<8> flag_value) {
        congestion_flag = (bit<1>) flag_value;
    }
#define TERNARY_NEG_CHECK 32w0x80000000 &&& 32w0x80000000
#define TERNARY_POS_CHECK 32w0 &&& 32w0x80000000
#define TERNARY_DONT_CARE 32w0 &&& 32w0
    @hidden
    table set_congestion_flag {
        key = {
            demand_delta : ternary;
        }
        actions = {
            set_congestion_flag_act;
        }
        const entries = {
            (TERNARY_NEG_CHECK) : set_congestion_flag_act(1);
        }
        default_action = set_congestion_flag_act(0);
        size = 1;
    }


    apply {
        demand_delta = vlink_capacity - vlink_demand;
        set_congestion_flag.apply();
    }
}
