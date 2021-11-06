// Approx UPF. Copyright (c) Princeton University, all rights reserved

#ifndef NUM_VLINKS
	#error "Please define NUM_VLINKS"
#endif

// Read out T, the per-threshold for how many bytes allowed per epoch 
control Threshld_Memory(in vlink_index_t vlink_index, in bool is_update, inout bytecount_t per_flow_threshold){
	Register<bytecount_t, vlink_index_t>(NUM_VLINKS) thresholds;

	RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(thresholds) load_threshold = {
        void apply(inout bytecount_t stored_threshold, out bytecount_t rv) {
            rv = stored_threshold;
 	   }
	};
	RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(thresholds) write_threshold = {
        void apply(inout bytecount_t stored_threshold, out bytecount_t rv) {
            stored_threshold = per_flow_threshold;
            rv = stored_threshold;
    	}
    };

	apply {
		if(is_update){
			//write new value
			write_threshold.execute(vlink_index);
		}else{
			//read out threshold
			per_flow_threshold=load_threshold.execute(vlink_index);
		}
	}
}