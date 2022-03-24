// Approx UPF. Copyright (c) Princeton University, all rights reserved

#include <core.p4>
#include <tna.p4>

#include "include/define.h"
#include "include/headers.h"
#include "include/metadata.h"
#include "include/parsers.h"

#include "include/vlink_lookup.p4"
#include "include/rate_estimator.p4"
#include "include/tcp_enforcer.p4"
#include "include/threshold_interpolator.p4"
#include "include/max_rate_estimator.p4"
#include "include/link_rate_tracker.p4"
#include "include/byte_dumps.p4"
#include "include/worker_generator.p4"
#include "include/update_storage.p4"


/* TODO: where should the packet cloning occur?
We should begin choosing a new candidate as soon as the window jumps.
To detect the jump, we'll need a register that stores "last epoch updated" per-vlink.
The window
*/

/*
Tofino-Approximate fair dropping:
- Load slice threshold, scale-up packet length:
- Approximate flow rate using a decaying CMS
- Set drop flag with probability 1 - min(1, T/Rate)
- Feed non-dropped packets into a rate-measuring LPF
- Adjust threshold based upon LPF output, using EWMA recurrence from AFD paper
*/



control SwitchIngress(
        inout header_t hdr,
        inout ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    VLinkLookup() vlink_lookup;
    RateEstimator() rate_estimator;
    TcpEnforcer() tcp_enforcer;
    ByteDumps() byte_dumps;
    WorkerGenerator() worker_generator;

    apply {
        epoch_t epoch = (epoch_t) ig_intr_md.ingress_mac_tstamp[47:20];//scale to 2^20ns ~= 1ms

        // load L4 ports for hashing
        if (hdr.udp.isValid()) {
            ig_md.sport = hdr.udp.src_port;
            ig_md.dport = hdr.udp.dst_port;
        } else if (hdr.tcp.isValid()) { 
            ig_md.sport = hdr.tcp.src_port;
            ig_md.dport = hdr.tcp.dst_port;
        } else {
            ig_md.sport = 0;
            ig_md.dport = 0;
        }
            

        // If the packet is a recirculated update, it will not survive vlink_lookup.
        vlink_lookup.apply(hdr, ig_md.afd, ig_tm_md.ucast_egress_port, ig_dprsr_md.drop_ctl, ig_tm_md.bypass_egress);

        bit<1> work_flag;
        worker_generator.apply(epoch, ig_md.afd.vlink_id, work_flag);
        if (work_flag == 1) {
            // A mirrored packet will be generated during deparsing
            ig_dprsr_md.mirror_type = MIRROR_TYPE_I2E;
            ig_md.mirror_session = THRESHOLD_UPDATE_MIRROR_SESSION;
            ig_md.mirror_bmd_type = BMD_TYPE_MIRROR;  // mirror digest fields cannot be immediates, so put this here
        } 

        // Approximately measure this flow's instantaneous rate.
        rate_estimator.apply(hdr.ipv4.src_addr,
                             hdr.ipv4.dst_addr,
                             hdr.ipv4.protocol,
                             ig_md.sport,
                             ig_md.dport,
                             ig_md.afd.scaled_pkt_len,
                             ig_md.afd.measured_rate);
			     
	// Debug rate output
	hdr.ethernet.src_addr=(bit<48>) ig_md.afd.measured_rate;

        // Get real drop flag and two simulated drop flags
        bit<1> afd_drop_flag_lo = 0;
// TODO: these annotations have no effect. Do we need to move these fields to metadata?
@pa_no_overlay("ingress", "afd_drop_flag_mid")
        bit<8> afd_drop_flag_mid = 0;
        bit<1> afd_drop_flag_hi = 0;
@pa_no_overlay("ingress", "ecn_flag")
@pa_no_overlay("ingress", "ig_dprsr_md.drop_ctl")
        bit<8> ecn_flag = 1;
        tcp_enforcer.apply(ig_md.afd.measured_rate,
                           hdr.ipv4.total_len,
                           ig_md.afd.threshold_lo,
                           ig_md.afd.threshold,
                           ig_md.afd.threshold_hi,
                             hdr.ipv4.src_addr,
                             hdr.ipv4.dst_addr,
                             hdr.ipv4.protocol,
                             ig_md.sport,
                             ig_md.dport,
                           afd_drop_flag_mid,
                           ecn_flag);
        if (afd_drop_flag_mid != 0) {
            ig_dprsr_md.drop_ctl = 1;
        }
        if (ecn_flag != 0) {
            if(hdr.ipv4.ecn != 0){
                hdr.ipv4.ecn = 0b11;
            }else{
                ig_dprsr_md.drop_ctl = 1;
            }    
        }
                            
                           
        /*
        rate_enforcer.apply(ig_md.afd.measured_rate,
                            ig_md.afd.threshold_lo,
                            ig_md.afd.threshold,
                            ig_md.afd.threshold_hi,
                            afd_drop_flag_lo,
                            afd_drop_flag_mid,
                            afd_drop_flag_hi);

        // || work_flag == 1 is defensive for debugging
        if (ig_md.afd.congestion_flag == 0 || work_flag == 1) {
	    // If congestion flag is false, dropping is disabled
            afd_drop_flag_mid = 0;
            ig_dprsr_md.drop_ctl = 0;
        } else if (afd_drop_flag_hi == 1) {
            // if drop_flag_hi, don't bother with ECN, just drop unconditionally
            ig_dprsr_md.drop_ctl = 1;
        } else if (hdr.tcp.isValid() && (hdr.ipv4.ecn != 0) && (afd_drop_flag_mid == 1)){
            ig_dprsr_md.drop_ctl = 0;
            hdr.ipv4.ecn = 0b11;
        } else {
            ig_dprsr_md.drop_ctl = (bit<3>) afd_drop_flag_mid;
        }
        */
        

        //always dump
            // Deposit or pick up packet bytecounts to allow the lo/hi drop
            // simulations to work around true dropping.
            byte_dumps.apply(ig_md.afd.vlink_id,
                             ig_md.afd.scaled_pkt_len,
                             afd_drop_flag_lo,
                             ig_dprsr_md.drop_ctl[0:0],
                             afd_drop_flag_hi,
                             ig_md.afd.bytes_sent_lo,
                             ig_md.afd.bytes_sent_hi,
                             ig_md.afd.bytes_sent_all);
    }
}


control SwitchEgress(
        inout header_t hdr,
        inout eg_metadata_t eg_md,
        in egress_intrinsic_metadata_t eg_intr_md,
        in egress_intrinsic_metadata_from_parser_t eg_prsr_md,
        inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_oport_md) {

    ThresholdInterpolator() threshold_interpolator;
    MaxRateEstimator() max_rate_estimator;
    LinkRateTracker() link_rate_tracker;
    UpdateStorage() update_storage;

    byterate_t vlink_rate;
    byterate_t vlink_rate_lo;
    byterate_t vlink_rate_hi;
    byterate_t vlink_demand;


    action load_vlink_capacity(byterate_t vlink_capacity) {
        eg_md.afd.vlink_capacity = vlink_capacity;
    }
    table capacity_lookup {
        key = {
            eg_md.afd.vlink_id : ternary;
        }
        actions = {
            load_vlink_capacity;
        }
        default_action = load_vlink_capacity(DEFAULT_VLINK_CAPACITY);
        size = NUM_VLINK_GROUPS;
    }

    Register<byterate_t, vlink_index_t>(size=NUM_VLINKS) egr_reg_thresholds;
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(egr_reg_thresholds) grab_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            stored = stored;
            retval = stored;
        }
    };
    RegisterAction<byterate_t, vlink_index_t, byterate_t>(egr_reg_thresholds) dump_new_threshold_regact = {
        void apply(inout byterate_t stored, out byterate_t retval) {
            stored = eg_md.afd.new_threshold;
            retval = stored;
        }
    };
    action grab_new_threshold() {
        hdr.afd_update.new_threshold = grab_new_threshold_regact.execute(eg_md.afd.vlink_id);
        // Finish setting the recirculation headers
        hdr.fake_ethernet.ether_type = ETHERTYPE_THRESHOLD_UPDATE;
        hdr.afd_update.vlink_id = eg_md.afd.vlink_id;
    }
    action dump_new_threshold() {
        dump_new_threshold_regact.execute(eg_md.afd.vlink_id);
        // Recirculation headers aren't needed, erase them
        hdr.fake_ethernet.setInvalid();
        hdr.afd_update.setInvalid();

    }

    table read_or_write_new_threshold {
        key = {
            eg_md.afd.is_worker : exact;
        }
        actions = {
            grab_new_threshold;
            dump_new_threshold;
        }
        const entries = {
            0 : dump_new_threshold();
            1 : grab_new_threshold();
        }
        size = 2;
    }


    byterate_t capacity_minus_demand; 

    Register<bit<8>, vlink_index_t>(size=NUM_VLINKS) egr_reg_flags;
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(egr_reg_flags) set_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
        stored_flag = 1;
        returned_flag = 1;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(egr_reg_flags) unset_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
        stored_flag = 0;
        returned_flag = 0;
        }
    };
    RegisterAction<bit<8>, vlink_index_t, bit<8>>(egr_reg_flags) grab_congestion_flag_regact = {
        void apply(inout bit<8> stored_flag, out bit<8> returned_flag) {
            returned_flag = stored_flag;
        }
    };
    action set_congestion_flag() {
        set_congestion_flag_regact.execute(eg_md.afd.vlink_id);
    }
    action unset_congestion_flag() {
       unset_congestion_flag_regact.execute(eg_md.afd.vlink_id);
    }
    action grab_congestion_flag() {
        hdr.afd_update.congestion_flag = (bit<1>) grab_congestion_flag_regact.execute(eg_md.afd.vlink_id);
    }
    action nop_(){}


    table read_or_write_congestion_flag {
        key = {
            eg_md.afd.is_worker : exact;
            capacity_minus_demand : ternary;
        }
        actions = {
            grab_congestion_flag;
            set_congestion_flag;
            unset_congestion_flag;
            nop_();
        }
        const entries = {
            (1, TERNARY_DONT_CARE) : grab_congestion_flag();
            (0, TERNARY_NEG_CHECK) : set_congestion_flag();     
            (0, TERNARY_POS_CHECK) : unset_congestion_flag();    
            (0, TERNARY_ZERO_CHECK) : unset_congestion_flag();
        }
        size = 8;
        default_action = nop_();  // Something went wrong, stick with the current fair rate threshold
    }

    apply { 
        hdr.fake_ethernet.setValid();
        hdr.afd_update.setValid();
        if (eg_md.afd.is_worker == 0) {
            capacity_lookup.apply();
            link_rate_tracker.apply(eg_md.afd.vlink_id, 
                                    eg_md.afd.scaled_pkt_len, 
                                    eg_md.afd.bytes_sent_all,
                                    eg_md.afd.bytes_sent_lo, 
                                    eg_md.afd.bytes_sent_hi,
                                    vlink_rate, 
                                    vlink_rate_lo, 
                                    vlink_rate_hi, 
                                    vlink_demand);
            
            capacity_minus_demand = eg_md.afd.vlink_capacity - vlink_demand; 

            threshold_interpolator.apply(
                vlink_rate, vlink_rate_lo, vlink_rate_hi,
                eg_md.afd.vlink_capacity, 
                eg_md.afd.threshold, eg_md.afd.threshold_lo, eg_md.afd.threshold_hi,
                eg_md.afd.candidate_delta_pow,
                eg_md.afd.new_threshold);
        }

        read_or_write_new_threshold.apply();
        read_or_write_congestion_flag.apply();
        // TODO: recirculate to every ingress pipe, not just one.
    }
}



Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
