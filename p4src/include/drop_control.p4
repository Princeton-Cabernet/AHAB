control DropControl(in bit<1> afd_drop_flag,
                    in bit<8> congestion_flag,
                    out bit<3> drop_ctl_out,
                    out bit<1> drop_withheld_out) {

    @hidden
    action set_drop_control_act(bit<3> drop_ctl) {
        drop_ctl_out = drop_ctl;
    }
    @hidden
    table set_drop_control {
        key = {
            afd_drop_flag : exact;
            congestion_flag : exact;
        }
        actions = { set_drop_control_act; }
        const entries = {
            (1, 1) : set_drop_control_act(1);
        }
        size = 1;
        default_action = set_drop_control_act(0);
    }

    @hidden
    action set_drop_withheld_act(bit<1> drop_withheld) {
        drop_withheld_out = drop_withheld;
    }
    @hidden
    table set_drop_withheld {
        key = {
            afd_drop_flag : exact;
            congestion_flag : exact;
        }
        actions = { set_drop_withheld_act; }
        const entries = {
            (1, 0) : set_drop_withheld_act(1);
        }
        size = 1;
        default_action = set_drop_withheld_act(0);
    }
    
    apply {
        set_drop_control.apply();
        set_drop_withheld.apply();
    }
}

