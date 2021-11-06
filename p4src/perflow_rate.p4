// Approx UPF. Copyright (c) Princeton University, all rights reserved

#ifndef CMS_HEIGHT
	#error "Please define CMS_HEIGHT"
#endif
// Window-based count-min sketch
control CountMinSketch(in  bit<32> flowID,
                       in  epoch_t epoch,
                       in  bytecount_t sketch_input,
                       out bytecount_t sketch_output) {
    /*
    The CMS consists of 2C registers, where C is the number of CMS columns.
    The first C registers are the usual CMS counters.
    The last C registers contain IDs of the last epochs when each CMS counter was reset
    If it is currently epoch 5, but the epoch register at index [i,j] contains epochID 4,
    then the CMS cell at index [i,j] needs to be reset for the new epoch.

    Step 1 is to read the epochID counters and check if the CMS cells that will be written
    need to be reset.
    Step 2a is to reset the CMS counter cells if necessary
    Step 2b is to increment and read the CMS counter cells
    Step 3 is to find the minimum of all the read CMS cells.
    */


    Register<bytecount_t,cms_index_t>(CMS_HEIGHT) cms_reg_1;
    Register<bytecount_t,cms_index_t>(CMS_HEIGHT) cms_reg_2;
    Register<bytecount_t,cms_index_t>(CMS_HEIGHT) cms_reg_3;

    Register<epoch_t, cms_index_t>(CMS_HEIGHT) last_wipe_epoch1;
    Register<epoch_t, cms_index_t>(CMS_HEIGHT) last_wipe_epoch2;
    Register<epoch_t, cms_index_t>(CMS_HEIGHT) last_wipe_epoch3;

    RegisterAction<epoch_t, cms_index_t, bit<1>>(last_wipe_epoch1) check_wipe1 = {
        void apply(inout epoch_t stored_epoch, out bit<1> needs_wipe) {
            if (stored_epoch == epoch) {
                needs_wipe = 1w0;
            } else {
                needs_wipe = 1w1;
                stored_epoch = epoch;
            }
        }
    };
    RegisterAction<epoch_t, cms_index_t, bit<1>>(last_wipe_epoch2) check_wipe2 = {
        void apply(inout epoch_t stored_epoch, out bit<1> needs_wipe) {
            if (stored_epoch == epoch) {
                needs_wipe = 1w0;
            } else {
                needs_wipe = 1w1;
                stored_epoch = epoch;
            }
        }
    };
    RegisterAction<epoch_t, cms_index_t, bit<1>>(last_wipe_epoch3) check_wipe3 = {
        void apply(inout epoch_t stored_epoch, out bit<1> needs_wipe) {
            if (stored_epoch == epoch) {
                needs_wipe = 1w0;
            } else {
                needs_wipe = 1w1;
                stored_epoch = epoch;
            }
        }
    };



    RegisterAction<bytecount_t, cms_index_t, bytecount_t>(cms_reg_1) reset_cms_reg_1 = {
        void apply(inout bytecount_t stored_val, out bytecount_t read_val) {
            stored_val = sketch_input;
            read_val = stored_val;
        }
    };
    RegisterAction<bytecount_t, cms_index_t, bytecount_t>(cms_reg_2) reset_cms_reg_2 = {
        void apply(inout bytecount_t stored_val, out bytecount_t read_val) {
            stored_val = sketch_input;
            read_val = stored_val;
        }
    };
    RegisterAction<bytecount_t, cms_index_t, bytecount_t>(cms_reg_3) reset_cms_reg_3 = {
        void apply(inout bytecount_t stored_val, out bytecount_t read_val) {
            stored_val = sketch_input;
            read_val = stored_val;
        }
    };

    RegisterAction<bytecount_t, cms_index_t, bytecount_t>(cms_reg_1) update_cms_reg_1 = {
        void apply(inout bytecount_t stored_val, out bytecount_t read_val) {
            stored_val = stored_val + sketch_input;
            read_val = stored_val;
        }
    };
    RegisterAction<bytecount_t, cms_index_t, bytecount_t>(cms_reg_2) update_cms_reg_2 = {
        void apply(inout bytecount_t stored_val, out bytecount_t read_val) {
            stored_val = stored_val + sketch_input;
            read_val = stored_val;
        }
    };
    RegisterAction<bytecount_t, cms_index_t, bytecount_t>(cms_reg_3) update_cms_reg_3 = {
        void apply(inout bytecount_t stored_val, out bytecount_t read_val) {
            stored_val = stored_val + sketch_input;
            read_val = stored_val;
        }
    };

    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_1;
    Hash<cms_index_t>(HashAlgorithm_t.CRC32) hash_2;
    Hash<cms_index_t>(HashAlgorithm_t.CRC32) hash_3;


    apply {
        cms_index_t index1 = hash_1.get({ flowID });
        cms_index_t index2 = hash_2.get({ 12w0x233,flowID });
        cms_index_t index3 = hash_3.get({ 21w0x4f567, flowID });

        // Step 1: check if CMS values should be reset
        bit<1> wipe1 = check_wipe1.execute(index1);
        bit<1> wipe2 = check_wipe2.execute(index2);
        bit<1> wipe3 = check_wipe3.execute(index3);

	    bytecount_t cms_output_1;
	    bytecount_t cms_output_2;
	    bytecount_t cms_output_3;

        // Step 2a and 2b: update and reaed the CMS values
        if (wipe1 == 1w1) {
            cms_output_1 = reset_cms_reg_1.execute(index1);
        } else {
            cms_output_1 = update_cms_reg_1.execute(index1);
        }
        if (wipe2 == 1w1) {
            cms_output_2 = reset_cms_reg_2.execute(index2);
        } else {
            cms_output_2 = update_cms_reg_2.execute(index2);
        }
        if (wipe3 == 1w1) {
            cms_output_3 = reset_cms_reg_3.execute(index3);
        } else {
            cms_output_3 = update_cms_reg_3.execute(index3);
        }

        // Step 3: find the minimum of the CMS values
        sketch_output = min<bytecount_t>(cms_output_1, cms_output_2);
        sketch_output = min<bytecount_t>(sketch_output, cms_output_3);
    }
}

control PerFlow_Rate_Estimator(in  bit<32> flowID,
                       in bit<8> epoch,
                       in bytecount_t my_pkt_size, 
                       out bytecount_t perflow_rate) {
	CountMinSketch() cms;
	apply{
		cms.apply(flowID,epoch,my_pkt_size,perflow_rate);
	}
}