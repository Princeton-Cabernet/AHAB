control WorkerGenerator(in epoch_t curr_epoch,
                         in vlink_index_t vlink_id,
                         out bit<3> mirror_type) {
    //reads vlink_id and epoch, trigger cloning for the first packet in new epoch
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
    apply {
        mirror_type = (bit<3>) choose_to_work.execute(vlink_id);
    }
}
