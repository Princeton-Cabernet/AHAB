/*******************************************************************************
 * BAREFOOT NETWORKS CONFIDENTIAL & PROPRIETARY
 *
 * Copyright (c) 2019-present Barefoot Networks, Inc.
 *
 * All Rights Reserved.
 *
 * NOTICE: All information contained herein is, and remains the property of
 * Barefoot Networks, Inc. and its suppliers, if any. The intellectual and
 * technical concepts contained herein are proprietary to Barefoot Networks, Inc.
 * and its suppliers and may be covered by U.S. and Foreign Patents, patents in
 * process, and are protected by trade secret or copyright law.  Dissemination of
 * this information or reproduction of this material is strictly forbidden unless
 * prior written permission is obtained from Barefoot Networks, Inc.
 *
 * No warranty, explicit or implicit is provided, unless granted under a written
 * agreement with Barefoot Networks, Inc.
 *
 ******************************************************************************/

#include <core.p4>
#include <tna.p4>

#include "include/headers.p4"
#include "include/util.p4"

#define CMS_HEIGHT 65536
#define NUM_VLINKS 1024
typedef bit<16> cms_index_t;
typedef bit<16> bytecount_t;
typedef bit<8> epoch_t;
typedef bit<16> vlink_index_t;

// maximum per-slice bytes sent per-window. Should be base station bandwidth * window duration
const bytecount_t FIXED_VLINK_CAPACITY = 65000;

struct candidate_count_pair_t {
    bytecount_t     candidate;
    bytecount_t     count;
}


enum bit<3> HqosPacketOp {
    DEFAULT             = 0x0,
    COMPUTE_THRESHOLD   = 0x1,
    WRITE_THRESHOLD     = 0x2,
}



// Window-based count-min sketch
control CountMinSketch(in  bytecount_t sketch_input,
                       out bytecount_t sketch_output,
                       in bit<8> epoch) {
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


    bytecount_t cms_output_1;
    bytecount_t cms_output_2;
    bytecount_t cms_output_3;



    Hash<cms_index_t>(HashAlgorithm_t.CRC_16) hash_1;
    Hash<cms_index_t>(HashAlgorithm_t.CRC_16) hash_2;
    Hash<cms_index_t>(HashAlgorithm_t.CRC_16) hash_3;

    cms_index_t index1;
    cms_index_t index2;
    cms_index_t index3;


    apply {
        index1 = hash1.get({ hdr.ipv4.proto,
                             hdr.ipv4.sip,
                             hdr.ipv4.dip,
                             ig_md.sport,
                             ig_md.dport });
        index2 = hash2.get({ hdr.ipv4.proto,
                             hdr.ipv4.sip,
                             hdr.ipv4.dip,
                             ig_md.sport,
                             ig_md.dport });
        index3 = hash3.get({ hdr.ipv4.proto,
                             hdr.ipv4.sip,
                             hdr.ipv4.dip,
                             ig_md.sport,
                             ig_md.dport });

        // Step 1: check if CMS values should be reset
        bit<1> wipe1 = check_wipe1.execute(index1);
        bit<1> wipe2 = check_wipe2.execute(index2);
        bit<1> wipe3 = check_wipe3.execute(index3);

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
        sketch_output = min<bit<16>>(cms_output_1, cms_output_2);
        sketch_output = min<bit<16>>(sketch_output, cms_output_3);
    }
}

control FairDropping(in bytecount_t curr_epoch_bytes,
                     in bytecount_t curr_threshold,
                     in vlink_index_t vlink_index,
                     inout bytecount_t curr_packet_bytes,
                     out bit<1> drop_flag) {


    Register<bytecount_t,vlink_index_t>(NUM_VLINKS) recently_dropped_bytes;

    RegisterAction<bytecount_t, vlink_index_t, bytecount_t> inc_dropped_bytes = {
        void apply(inout bytecount_t stored_dropped_bytes, out bytecount_t rv) {
            stored_dropped_bytes = stored_dropped_bytes + curr_packet_bytes;
        }
    }
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t> fetch_dropped_bytes = {
        void apply(inout bytecount_t stored_dropped_bytes, out bytecount_t rv) {
            rv = stored_dropped_bytes;
            stored_dropped_bytes = 0;
        }
    }
    

    bytecount_t curr_threshold;

    bit<10> curr_counter_index;

    action load_quantile_index(bit<10> quantile_index) {
        curr_counter_index = quantile_index;
    }
    table lookup_curr_quantile {
        key = {
            curr_epoch_bytes  : ternary;
        }
        actions = {
            load_quantile_index;
        }
        size = 1024;
    }


    apply {
        // Check if bytes sent by current flow exceed the threshold
        if (curr_epoch_bytes > curr_threshold) {
            drop_flag = 1w1;
            inc_dropped_bytes.execute(vlink_index);
        } else {
            drop_flag = 1w0;
            curr_packet_bytes = curr_packet_bytes + fetch_dropped_bytes.execute(vlink_index);
        }
    }
}

control ThresholdsIngress(in HqosPacketOp operation,
                          in bytecount_t curr_flow_bytes,
                          in vlink_index_t vlink_index,
                          inout bit<1> drop_flag,
                          inout bytecount_t threshold) {
    Register<bytecount_t, vlink_index_t>(NUM_VLINKS) thresholds;

    // If control argument 'threshold' is nonzero, then this packet is an update packet that 
    // seeks to overwrite the current threshold. Otherwise, read and return the stored threshold.
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t> load_or_write_threshold(thresholds) = {
        void apply(inout bytecount_t stored_threshold, out bytecount_t rv) {
            if (threshold != 0) {
                stored_threshold = threshold;
            }
            rv = stored_threshold;
    }

    RegisterAction<bytecount_t, vlink_index_t, bytecount_t> compare_to_threshold(thresholds) = {
        void apply(inout bytecount_t stored_threshold, out bytecount_t rv) {
            if (curr_flow_bytes > stored_threshold) {
                rv = 1;
            } else {
                rv = 0;
            }


    apply {
        // If recirculated, write threshold, and then compute new candidates for storing in egress
        if (operation == HqosPacketOp.DEFAULT) {
            drop_flag = compare_to_threshold.execute(vlink_index);
        }
        // otherwise load and return threshold
        threshold = load_or_write_threshold.execute(vlink_index);
        if (operation == HqosPacketOp.WRITE_THRESHOLD) {
            // compute new candidates and load them into an 'out' struct
        }
    }
}


control ThresholdsEgress(in bytecount_t curr_threshold,
                         in bytecount_t curr_packet_bytes,
                         in vlink_index_t link_index,
                         in bytecount_t vlink_capacity,
                         in HqosPacketOp operation) {
    // TODO: replicate these N times for N threshold candidates
    Register<candidate_count_pair_t, vlink_index_t>(NUM_VLINKS) candidate_counts1;

    // Return the candidate threshold if it would not have exceeded the vlink capacity, and 0 otherwise
    RegisterAction<bytecount_t, vlink_index_t, bytecount_t> cmp_and_load_candidate1(candidate_counts1) = {
        void apply(inout candidate_count_pair_t pair, out bytecount_t rv) {
            if (pair.count < vlink_capacity) {
                rv = pair.candidate;
            } else {
                rv = 0;
            }
        }
    }
    
    // Replaces the candidate threshold stored in register_hi, and resets the candidate's counter
    RegisterAction<candidate_count_pair_t, vlink_index_t, bytecount_t> replace_candidate1(candidate_counts1) = {
        void apply(inout candidate_count_pair_t pair, out bytecount_t rv) {
            pair.candidate = new_candidates.one;
            pair.count = 0;
        }
    }

    // If the current flow's bytes sent during the current window do not exceed the candidate in register_hi,
    // increment the candidate's "bytes that would've been sent if I was the threshold" counter in register_lo
    RegisterAction<candidate_count_pair_t, vlink_index_t, bytecount_t> increment_candidate1(candidate_counts1) = {
        void apply(inout candidate_count_pair_t pair, out bytecount_t rv) {
            if (pair.candidate > curr_packet_bytes) {
                pair.count += curr_packet_bytes;
            }
        }
    }


    apply {
        bytecount_t winning_candidate;

        if (operation == HqosPacketOp.DEFAULT) {
            increment_candidate1.execute(vlink_index);
            // ...
        } 
        else if (operation == HqosPacketOp.COMPUTE_THRESHOLD) {
            // Load all candidate thresholds whos counters do not exceed the link capacity
            // If a candidate's counter exceeded the link capacity, the register action returns 0
            bytecount_t candidate1 = cmp_and_load_candidate1.execute(vlink_index);
            // ...
            // Find the maximum candidate with a binary tree of `max` externs
            bytecount_t winner_tmp1 = max<bit<16>>(candidate1, candidate2);
            bytecount_t winner_tmp2 = max<bit<16>>(candidate3, candidate4);
            winning_candidate            = max<bit<16>>(winner_tmp1, winner_tmp2);
        } 
        else if (operation == HqosPacketOp.WRITE_THRESHOLD) {
            // Write the new candidate thresholds and clear the candidate counters
            replace_candidate1.execute(vlink_index);
            // ...
        }


        if (operation == HqosPacketOp.COMPUTE_THRESHOLD) {
            // recirculate winning candidate threshold to ingress
        }
    }
}

control VlinkCapacities(in vlink_index_t vlink_index,
                        out bytecount_t vlink_capacitiy) {
    // For determining per-vlink capacities.
    // For now, capacities are fixed, so just return a constant.
    apply {
        vlink_capacity = FIXED_VLINK_CAPACITY;
    }
}




struct metadata_t {}


/* TODO: where should the packet cloning occur?
We should begin choosing a new candidate as soon as the window jumps.
To detect the jump, we'll need a register that stores "last epoch updated" per-vlink.
The window
*/

control SwitchIngress(
        inout header_t hdr,
        inout metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    bit<8> epoch;
    bytecount_t packet_size;
    bytecount_t flow_size;
    bytecount_t threshold;
    // Vlink ID = (base_station_id << 4) ++ slice_id
    vlink_index_t vlink_id;
    vlink_index_t slice_id;
    vlink_index_t base_station_id;
    bit<8> vlink_scale;
    HqosPacketOp operation = HqosPacketOp.DEFAULT;
    
    CountMinSketch() count_min_sketch;
    ThresholdsIngress() threshold_control;

 
    /* vlink_scale is a positive integer used to right-shift the packet size, for scaling
     * the packet size before updating the HH sketch.
     */
    action load_flow_info(vlink_index_t vlink_id_arg, bit<8> vlink_scale_arg) {
        // scale packet size by the vlink's scaling factor, for the HH sketch
        vlink_id = vlink_id_arg;
        slice_id = vlink_id_arg & 0x15;
        base_station_id = vlink_id_arg >> 4;
        vlink_scape = vlink_scale_arg;
        packet_size = packet_size << vlink_scale_arg;
    }
        


    apply {
        epoch = (bit<8>)ingress_mac_tstamp[27:20];
        if (RECIRC_FLAG) {
            operation = recirc_header.operation;
        }
        // vlink lookup

        // CMS
        count_min_sketch.apply(packet_size, flow_size, epoch);
        // Load or overwrite threshold
        threshold_control.apply(operation, vlink_index, threshold);

        // Decide to drop or not
    }
}


control SwitchEgress(
        inout header_t hdr,
        inout egress_metadata_t eg_md,
        in egress_intrinsic_metadata_t eg_intr_md,
        in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
        inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_oport_md) {


    apply {
        // Load vlink capacity
        // Update candidate counters and/or choose a winning candidate threshold
        // Dump winning candidate threshold into mirrored+recirculated packet
    }
}



Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
