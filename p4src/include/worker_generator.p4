control WorkerGenerator(in epoch_t curr_epoch,
                         in vlink_index_t vlink_id,
                         out bit<3> mirror_type,
                         out MirrorId_t mirror_session,
                         out bridged_metadata_type_t mirror_bmd_type) {
    //reads vlink_id and epoch, generate is_worker for the first packet in new epoch
    @hidden
    Register<epoch_t, vlink_index_t>(NUM_VLINKS) last_worker_epoch;
    RegisterAction<epoch_t, vlink_index_t, bit<8>>(last_worker_epoch) choose_to_work = {
        void apply(inout epoch_t stored_epoch, out bit<8> rv) {
            if (stored_epoch == curr_epoch) {
                rv = (bit<8>) MIRROR_TYPE_I2E;
            } else {
                rv = 0;
                stored_epoch = curr_epoch;
            }
        }
    };
    @hidden
    action choose_to_work_act() {
        mirror_type = (bit<3>) choose_to_work.execute(vlink_id);
        // Set unconditionally, because they are discarded anyway if mirroring doesn't occur
        mirror_session = THRESHOLD_UPDATE_MIRROR_SESSION;
        mirror_bmd_type = BMD_TYPE_MIRROR;  // mirror digest fields cannot be immediates, so put this here
    }
    bit<1> dummy_bit=0;
    @hidden
    action choose_to_work_default() {
        // Action will never execute. Silences compiler re: uninitialized fields
        mirror_type = 0; 
        // Set unconditionally, because they are discarded anyway if mirroring doesn't occur
        mirror_session = THRESHOLD_UPDATE_MIRROR_SESSION;
        mirror_bmd_type = BMD_TYPE_MIRROR;  // mirror digest fields cannot be immediates, so put this here
    }
    @hidden
    table choose_to_work_tbl {
        key = { dummy_bit : exact; }
        actions = { choose_to_work_act; choose_to_work_default; }
        const entries = { 0 : choose_to_work_act(); }
        default_action = choose_to_work_default();
        size = 1;
    }

    apply {
        choose_to_work_tbl.apply();
    }
}
