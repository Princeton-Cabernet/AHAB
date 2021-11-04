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
#define HH_CACHE_HEIGHT 65536
#define ROUTE_REG_HEIGHT 262144
#define ROUTE_REG_INDEX_WIDTH 18
#define NUM_VLINKS 1024
typedef bit<20> route_reg_index_t;
typedef bit<18> route_reg_subindex_t;
typedef bit<8> route_reg_entry_t;
typedef bit<16> cms_index_t;
typedef bit<16> flow_bytecount_t;
typedef bit<8> epoch_t;
typedef bit<16> slice_index_t;

// maximum per-slice bytes sent per-window. Should be base station bandwidth * window duration
const flow_bytecount_t FIXED_VLINK_CAPACITY = 65000;

struct candidate_count_pair_t {
    flow_bytecount_t     candidate;
    flow_bytecount_t     count;
}


enum bit<3> HqosPacketOp {
    DEFAULT             = 0x0,
    COMPUTE_THRESHOLD   = 0x1,
    WRITE_THRESHOLD     = 0x2,
}



// Window-based count-min sketch
control CountMinSketch(in  flow_bytecount_t sketch_input,
                       out flow_bytecount_t sketch_output,
                       in bit<48> ingress_mac_tstamp) {
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

    bit<8> epoch = (bit<8>)ingress_mac_tstamp[27:20];

    Register<flow_bytecount_t,cms_index_t>(CMS_HEIGHT) cms_reg_1;
    Register<flow_bytecount_t,cms_index_t>(CMS_HEIGHT) cms_reg_2;
    Register<flow_bytecount_t,cms_index_t>(CMS_HEIGHT) cms_reg_3;

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



    RegisterAction<flow_bytecount_t, cms_index_t, flow_bytecount_t>(cms_reg_1) reset_cms_reg_1 = {
        void apply(inout flow_bytecount_t stored_val, out flow_bytecount_t read_val) {
            stored_val = sketch_input;
            read_val = stored_val;
        }
    };
    RegisterAction<flow_bytecount_t, cms_index_t, flow_bytecount_t>(cms_reg_2) reset_cms_reg_2 = {
        void apply(inout flow_bytecount_t stored_val, out flow_bytecount_t read_val) {
            stored_val = sketch_input;
            read_val = stored_val;
        }
    };
    RegisterAction<flow_bytecount_t, cms_index_t, flow_bytecount_t>(cms_reg_3) reset_cms_reg_3 = {
        void apply(inout flow_bytecount_t stored_val, out flow_bytecount_t read_val) {
            stored_val = sketch_input;
            read_val = stored_val;
        }
    };

    RegisterAction<flow_bytecount_t, cms_index_t, flow_bytecount_t>(cms_reg_1) update_cms_reg_1 = {
        void apply(inout flow_bytecount_t stored_val, out flow_bytecount_t read_val) {
            stored_val = stored_val + sketch_input;
            read_val = stored_val;
        }
    };
    RegisterAction<flow_bytecount_t, cms_index_t, flow_bytecount_t>(cms_reg_2) update_cms_reg_2 = {
        void apply(inout flow_bytecount_t stored_val, out flow_bytecount_t read_val) {
            stored_val = stored_val + sketch_input;
            read_val = stored_val;
        }
    };
    RegisterAction<flow_bytecount_t, cms_index_t, flow_bytecount_t>(cms_reg_3) update_cms_reg_3 = {
        void apply(inout flow_bytecount_t stored_val, out flow_bytecount_t read_val) {
            stored_val = stored_val + sketch_input;
            read_val = stored_val;
        }
    };


    flow_bytecount_t cms_output_1;
    flow_bytecount_t cms_output_2;
    flow_bytecount_t cms_output_3;



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

control FairDropping(in flow_bytecount_t curr_epoch_bytes,
                     in flow_bytecount_t curr_threshold,
                     in vlink_index_t vlink_index,
                     inout flow_bytecount_t curr_packet_bytes,
                     out bit<1> drop_flag) {


    Register<flow_bytecount_t,vlink_index_t>(NUM_VLINKS) recently_dropped_bytes;

    RegisterAction<flow_bytecount_t, vlink_index_t, flow_bytecount_t> inc_dropped_bytes = {
        void apply(inout flow_bytecount_t stored_dropped_bytes, out flow_bytecount_t rv) {
            stored_dropped_bytes = stored_dropped_bytes + curr_packet_bytes;
        }
    }
    RegisterAction<flow_bytecount_t, vlink_index_t, flow_bytecount_t> fetch_dropped_bytes = {
        void apply(inout flow_bytecount_t stored_dropped_bytes, out flow_bytecount_t rv) {
            rv = stored_dropped_bytes;
            stored_dropped_bytes = 0;
        }
    }
    

    flow_bytecount_t curr_threshold;

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
                          in vlink_index_t vlink_index,
                          inout flow_bytecount_t new_threshold) {
    Register<flow_bytecount_t, vlink_index_t>(NUM_VLINKS) thresholds;

    RegisterAction<flow_bytecount_t, vlink_index_t, flow_bytecount_t> load_or_write_threshold(thresholds) = {
        void apply(inout flow_bytecount_t stored_threshold, out flow_bytecount_t rv) {
            if (new_threshold != 0) {
                stored_threshold = new_threshold;
            }
            rv = stored_threshold;
    }


    apply {
        // If recirculated, write threshold, and then compute new candidates for storing in egress
        // otherwise load and return threshold
        flow_bytecount_t curr_threshold = load_or_write_threshold.execute(vlink_index);
        if (operation == HqosPacketOp.WRITE_THRESHOLD) {
            // compute new candidates and load them into an 'out' struct
        }
    }
}


control ThresholdsEgress(in flow_bytecount_t curr_threshold,
                         in flow_bytecount_t curr_packet_bytes,
                         in vlink_index_t link_index,
                         in flow_bytecount_t vlink_capacity,
                         in HqosPacketOp operation) {
    // TODO: replicate these N times for N threshold candidates
    Register<candidate_count_pair_t, vlink_index_t>(NUM_VLINKS) candidate_counts1;

    // Return the candidate threshold if it would not have exceeded the vlink capacity, and 0 otherwise
    RegisterAction<flow_bytecount_t, vlink_index_t, flow_bytecount_t> cmp_and_load_candidate1(candidate_counts1) = {
        void apply(inout candidate_count_pair_t pair, out flow_bytecount_t rv) {
            if (pair.count < vlink_capacity) {
                rv = pair.candidate;
            } else {
                rv = 0;
            }
        }
    }
    
    // Replaces the candidate threshold stored in register_hi, and resets the candidate's counter
    RegisterAction<candidate_count_pair_t, vlink_index_t, flow_bytecount_t> replace_candidate1(candidate_counts1) = {
        void apply(inout candidate_count_pair_t pair, out flow_bytecount_t rv) {
            pair.candidate = new_candidates.one;
            pair.count = 0;
        }
    }

    // If the current flow's bytes sent during the current window do not exceed the candidate in register_hi,
    // increment the candidate's "bytes that would've been sent if I was the threshold" counter in register_lo
    RegisterAction<candidate_count_pair_t, vlink_index_t, flow_bytecount_t> increment_candidate1(candidate_counts1) = {
        void apply(inout candidate_count_pair_t pair, out flow_bytecount_t rv) {
            if (pair.candidate > curr_packet_bytes) {
                pair.count += curr_packet_bytes;
            }
        }
    }


    apply {
        flow_bytecount_t winning_candidate;

        if (operation == HqosPacketOp.DEFAULT) {
            increment_candidate1.execute(vlink_index);
            // ...
        } 
        else if (operation == HqosPacketOp.COMPUTE_THRESHOLD) {
            // Load all candidate thresholds whos counters do not exceed the link capacity
            // If a candidate's counter exceeded the link capacity, the register action returns 0
            flow_bytecount_t candidate1 = cmp_and_load_candidate1.execute(vlink_index);
            // ...
            // Find the maximum candidate with a binary tree of `max` externs
            flow_bytecount_t winner_tmp1 = max<bit<16>>(candidate1, candidate2);
            flow_bytecount_t winner_tmp2 = max<bit<16>>(candidate3, candidate4);
            winning_candidate            = max<bit<16>>(winner_tmp1, winner_tmp2);
        } 
        else if (operation == HqosPacketOp.WRITE_THRESHOLD) {
            // Write the new candidate thresholds and clear the candidate counters
            replace_candidate1.execute(vlink_index);
            // ...
        }


        // recirculate winning candidate threshold to ingress



        // If compute_winner == 0:
        // |- Increment per-candidate counters for each candidate that was not exceeded
        // If compute_winner == 1:
        // |- Load all candidate counters
        // |- Find the largest candidate whose counter does not exceed vlink_capacity
        // |- Recirculate the winning candidate


    }



}

control SliceCapacities(in vlink_index_t vlink_index,
                        out flow_bytecount_t vlink_capacitiy) {
    // For determining per-vlink capacities. Currently capacities are fixed
    apply {
        vlink_capacity = FIXED_VLINK_CAPACITY;
    }
}





control BaseStationLookupRegBased(in route_reg_index_t ue_id,
                                  out route_reg_entry_t base_station_id) {
    Register<route_reg_entry_t, route_reg_subindex_t>(ROUTE_REG_HEIGHT) route_reg_stage_1;
    Register<route_reg_entry_t, route_reg_subindex_t>(ROUTE_REG_HEIGHT) route_reg_stage_2;
    Register<route_reg_entry_t, route_reg_subindex_t>(ROUTE_REG_HEIGHT) route_reg_stage_3;
    Register<route_reg_entry_t, route_reg_subindex_t>(ROUTE_REG_HEIGHT) route_reg_stage_4;

    RegisterAction<route_reg_entry_t, route_reg_subindex_t, route_reg_entry_t>(route_reg_stage_1) read_reg_1 = {
        void apply(inout route_reg_entry_t value, out route_reg_entry_t rv) {
            rv = value;
        }
    }
    RegisterAction<route_reg_entry_t, route_reg_subindex_t, route_reg_entry_t>(route_reg_stage_2) read_reg_2 = {
        void apply(inout route_reg_entry_t value, out route_reg_entry_t rv) {
            rv = value;
        }
    }
    RegisterAction<route_reg_entry_t, route_reg_subindex_t, route_reg_entry_t>(route_reg_stage_3) read_reg_3 = {
        void apply(inout route_reg_entry_t value, out route_reg_entry_t rv) {
            rv = value;
        }
    }
    RegisterAction<route_reg_entry_t, route_reg_subindex_t, route_reg_entry_t>(route_reg_stage_4) read_reg_4 = {
        void apply(inout route_reg_entry_t value, out route_reg_entry_t rv) {
            rv = value;
        }
    }

    apply {
        bit<2> register_stage = ue_id[19:18];
        route_reg_subindex_t register_index = ue_id[17:0];

        if        (register_stage == 2w0) {
            base_station_id = read_reg_1.execute(register_index);
        } else if (register_stage == 2w1) {
            base_station_id = read_reg_2.execute(register_index);
        } else if (register_stage == 2w2) {
            base_station_id = read_reg_3.execute(register_index);
        } else if (register_stage == 2w3) {
            base_station_id = read_reg_4.execute(register_index);
        }
    }
}

control BaseStationLookupTableBased(in route_reg_index_t ue_id,
                                    out route_reg_entry_t base_station_id) {
    action load_base_station_id(bs_id) {
        base_station_id = bs_id;
    }
    @ways(1)
    table base_station_lookup {
        key = {
            ue_id : exact   @name("ue_id");
        }
        actions = {
            load_base_station_id;
        }
        const size = ROUTE_REG_HEIGHT * 4;
    }
    apply {
        base_station_lookup.apply();
    }
}


control IngressRateLimit(in bit<16> observed_rate,
                         in bit<16> egress_spec,
                         in slice_index_t slice_id,
                         in bit<1> update_flag,
                         in bit<16> update_from_egress,
                         inout bit<1> drop_flag) {
    /*
    There is a per-port threshold stored in a register, with port number being the index.
    When per-port queue occupancy reports arrive from egress for a specific port, the threshold for
    that port is updated. If queue occupancy is low, increase the threshold. If it is high, decrease
    the threshold.
    */
    flow_bytecount_t curr_threshold;

    Register<bit<16>, bit<16>> per_port_thresholds;
    Register<flow_bytecount_t, slice_index_t> threshold_candidate_1;
    Register<flow_bytecount_t, slice_index_t> threshold_candidate_2;
    Register<flow_bytecount_t, slice_index_t> threshold_candidate_3;


    RegisterAction<bit<16>, bit<16>, bit<16>> update_threshold(per_port_thresholds) = {
        void apply(inout bit<16> value) {
            value = update_from_egress; 
        }
    };
    RegisterAction<bit<16>, bit<16>, bit<16>> get_threshold(per_port_thresholds) = {
        void apply(inout bit<16> value, out bit<16> rv) {
            rv = value;
        }
    };


    apply {
        if (update_flag == 1w1) {
            // update threshold
        } else {
            curr_threshold = get_threshold.execute(slice_id);
        }
        flow_bytecount_t threshold_1 = curr_threshold >> 1; // T / 2
        flow_bytecount_t threshold_2 = curr_threshold;      // T
        flow_bytecount_t threshold_3 = curr_threshold << 1; // T * 2

        flow_bytecount_t t_diff_1 = observed_rate - threshold1;
        flow_bytecount_t t_diff_2 = observed_rate - threshold2;
        flow_bytecount_t t_diff_3 = observed_rate - threshold3;

        // Get the most-significant bit
        t_diff_1 = t_diff_1 >> 15;
        t_diff_2 = t_diff_2 >> 15;
        t_diff_3 = t_diff_3 >> 15;

        bit<1> do_inc_reg_1 = (t_diff_1 == 1);
        bit<1> do_inc_reg_2 = (t_diff_2 == 1);
        bit<1> do_inc_reg_3 = (t_diff_3 == 1);

    }
}





struct metadata_t {}


control SwitchIngress(
        inout header_t hdr,
        inout metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    BaseStationLookupRegBased() bs_lookup;
    //BaseStationLookupTableBased() bs_lookup;
    LpfMinSketch()  lpf_min_sketch;

    bit<16> curr_rate;

    bs_lookup.apply(hdr.ipv4.dst_addr[19:0], bs_id);
    lpf_min_sketch.apply(hdr.ipv4.total_len, curr_rate);


    const bit<32> bool_register_table_size = 1 << 10;
    Register<bit<1>, bit<32>>(bool_register_table_size, 0) bool_register_table;
    // A simple one-bit register action that returns the inverse of the value
    // stored in the register table.
    RegisterAction<bit<1>, bit<32>, bit<1>>(bool_register_table) bool_register_table_action = {
        void apply(inout bit<1> val, out bit<1> rv) {
            rv = ~val;
        }
    };

    Register<pair, bit<32>>(32w1024) test_reg;
    // A simple dual-width 32-bit register action that will increment the two
    // 32-bit sections independently and return the value of one half before the
    // modification.
    RegisterAction<pair, bit<32>, bit<32>>(test_reg) test_reg_action = {
        void apply(inout pair value, out bit<32> read_value){
            read_value = value.second;
            value.first = value.first + 1;
            value.second = value.second + 100;
        }
    };

    action register_action(bit<32> idx) {
        test_reg_action.execute(idx);
    }

    table reg_match {
        key = {
            hdr.ethernet.dst_addr : exact;
        }
        actions = {
            register_action;
        }
        size = 1024;
    }

    DirectRegister<pair>() test_reg_dir;
    // A simple dual-width 32-bit register action that will increment the two
    // 32-bit sections independently and return the value of one half before the
    // modification.
    DirectRegisterAction<pair, bit<32>>(test_reg_dir) test_reg_dir_action = {
        void apply(inout pair value, out bit<32> read_value){
            read_value = value.second;
            value.first = value.first + 1;
            value.second = value.second + 100;
        }
    };

    action register_action_dir() {
        test_reg_dir_action.execute();
    }

    table reg_match_dir {
        key = {
            hdr.ethernet.src_addr : exact;
        }
        actions = {
            register_action_dir;
        }
        size = 1024;
        registers = test_reg_dir;
    }

    apply {
        bs_lookup.apply(ue_id, bs_id);
        lpf_min_sketch.apply(sketch_input, sketch_output);

        reg_match.apply();
        reg_match_dir.apply();
        bit<32> idx_ = 1;
        // Purposely assigning bypass_egress field like this so that the
        // compiler generates a match table internally for this register
        // table. (Note that this internally generated table is not
        // published in bf-rt.json but is only published in context.json)
        ig_tm_md.bypass_egress = bool_register_table_action.execute(idx_);
        // Send the packet back where it came from.
        ig_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
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
        // Dump winning threshold into mirror
    }
}



Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
