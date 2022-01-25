control WorkerGeneration(inout afd_metadata_t afd_md) {
    //reads vlink_id and epoch, generate is_worker for the first packet in new epoch
    @hidden
    Register<epoch_t, vlink_index_t>(NUM_VLINKS) last_worker_epoch;
    RegisterAction<epoch_t, vlink_index_t, bit<1>>(last_worker_epoch) choose_to_work = {
        void apply(inout epoch_t stored_epoch, out bit<1> time_to_work) {
            if (stored_epoch == afd_md.epoch) {
                time_to_work = 1w0;
            } else {
                time_to_work = 1w1;
                stored_epoch = afd_md.epoch;
            }
        }
    };
    @hidden
    action choose_to_work_act() {
        afd_md.is_worker = choose_to_work.execute(afd_md.vlink_id);
    }
    bit<1> dummy_bit=0;
    @hidden
    table choose_to_work_tbl {
        key = { dummy_bit : exact; }
        actions = { choose_to_work_act; }
        const entries = { 0 : choose_to_work_act(); }
        size = 1;
    }

    apply {
        choose_to_work_tbl.apply();
    }
}
