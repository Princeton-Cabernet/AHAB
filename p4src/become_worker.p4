// Approx UPF. Copyright (c) Princeton University, all rights reserved

#ifndef NUM_VLINKS
	#error "Please define NUM_VLINKS"
#endif


// Read out T, the per-threshold for how many bytes allowed per epoch 
control Become_Worker_Check(in vlink_index_t vlink_index, in epoch_t epoch, out bool become_worker){
	Register<epoch_t, vlink_index_t>(NUM_VLINKS) latest_epoch;

	RegisterAction<epoch_t, cms_index_t, bit<1>>(latest_epoch) check_wipe = {
        void apply(inout epoch_t stored_epoch, out bit<1> needs_wipe) {
            if (stored_epoch == epoch) {
                needs_wipe = 1w0;
            } else {
                needs_wipe = 1w1;
                stored_epoch = epoch;
            }
        }
    };
    action reg_exec(){
    	become_worker=(bool) check_wipe.execute(vlink_index);
    }

	apply {
		reg_exec();
	}
}