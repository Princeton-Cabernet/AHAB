/*
    AHAB project
    Copyright (c) 2022, Robert MacDavid, Xiaoqi Chen, Princeton University.
    macdavid [at] cs.princeton.edu

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.
    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#include <core.p4>
#include <tna.p4>

#include "include/define.h"
#include "include/headers.h"
#include "include/metadata.h"
#include "include/parsers.h"

#include "include/vlink_lookup.p4"
#include "include/rate_estimator.p4"
#include "include/rate_enforcer.p4"
#include "include/threshold_interpolator.p4"
#include "include/link_rate_tracker.p4"
#include "include/byte_dumps.p4"
#include "include/worker_generator.p4"
#include "include/update_storage.p4"

control SwitchIngress(
        inout header_t hdr,
        inout ig_metadata_t ig_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    VLinkLookup() vlink_lookup;
    RateEstimator() rate_estimator;
    RateEnforcer() rate_enforcer;
    ByteDumps() byte_dumps;
    WorkerGenerator() worker_generator;

    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_index;

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

        // Get real drop flag and two simulated drop flags
        bit<1> udp_drop_flag_lo = 0;
        bit<1> udp_drop_flag_mid = 0;
        bit<1> udp_drop_flag_hi = 0;
        bit<1> tcp_drop_flag_mid = 0;
        bit<8> ecn_flag = 1;

        bool tcp_isValid=hdr.tcp.isValid();
        cms_index_t reg_index = hash_index.get({
            hdr.ipv4.src_addr,hdr.ipv4.dst_addr,
            hdr.tcp.src_port,hdr.tcp.dst_port});

        bit<32> copied_rate;
        @in_hash{ copied_rate=ig_md.afd.measured_rate; }

        bit<32> copied_t_lo;
        bit<32> copied_t_mid;
        bit<32> copied_t_hi;
        @in_hash{ copied_t_lo=ig_md.afd.threshold_lo;  }
        @in_hash{ copied_t_mid=ig_md.afd.threshold;  }
        @in_hash{ copied_t_hi=ig_md.afd.threshold_hi;  }

        rate_enforcer.apply(copied_rate,//ig_md.afd.measured_rate,
                           copied_t_lo,//ig_md.afd.threshold_lo,
                           copied_t_mid,//ig_md.afd.threshold,
                           copied_t_hi,//ig_md.afd.threshold_hi,
                           tcp_isValid,
                           ig_md.afd.scaled_pkt_len,
                           reg_index,
                           udp_drop_flag_lo,
                           udp_drop_flag_mid,
                           udp_drop_flag_hi,
                           tcp_drop_flag_mid,
                           ecn_flag);

        if(tcp_isValid){
            if(tcp_drop_flag_mid!=0){
                ig_dprsr_md.drop_ctl = 1;
            }else if(hdr.ipv4.ecn != 0 && ecn_flag!=0){
                hdr.ipv4.ecn = 0b11;
                ig_dprsr_md.drop_ctl = 0;
            }else if(ecn_flag!=0){
                ig_dprsr_md.drop_ctl = 1;
            }
            //override hypothetical rate accumulator
            udp_drop_flag_lo=tcp_drop_flag_mid;
            udp_drop_flag_hi=0;
        }else{//udp
            if (ig_md.afd.congestion_flag == 0 || work_flag == 1) {
                ig_dprsr_md.drop_ctl = 0;
            }else if(udp_drop_flag_mid!=0){
                ig_dprsr_md.drop_ctl = 1;
            }else{
                ig_dprsr_md.drop_ctl = 0;
            }
        }
         
            // Deposit or pick up packet bytecounts to allow the lo/hi drop
            // simulations to work around true dropping.
            byte_dumps.apply(ig_md.afd.vlink_id,
                             (bit<32>) hdr.ipv4.total_len,
                             udp_drop_flag_lo,
                             ig_dprsr_md.drop_ctl[0:0],
                             udp_drop_flag_hi,
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
    LinkRateTracker() link_rate_tracker;
    UpdateStorage() update_storage;

    byterate_t vlink_rate = 0;
    byterate_t vlink_rate_lo = 0;
    byterate_t vlink_rate_hi = 0;
    byterate_t vlink_demand = 0;


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

    apply { 
        hdr.fake_ethernet.setValid();
        hdr.afd_update.setValid();
        if (eg_md.afd.is_worker == 0) {
            capacity_lookup.apply();
            link_rate_tracker.apply(eg_md.afd.vlink_id, 
                                    (bit<32>) hdr.ipv4.total_len, 
                                    eg_md.afd.bytes_sent_all,
                                    eg_md.afd.bytes_sent_lo, 
                                    eg_md.afd.bytes_sent_hi,
                                    vlink_rate, 
                                    vlink_rate_lo, 
                                    vlink_rate_hi, 
                                    vlink_demand);
            
            threshold_interpolator.apply(
                vlink_rate, vlink_rate_lo, vlink_rate_hi,
                eg_md.afd.vlink_capacity, 
                eg_md.afd.threshold, eg_md.afd.threshold_lo, eg_md.afd.threshold_hi,
                eg_md.afd.candidate_delta_pow,
                eg_md.afd.new_threshold);
        }

        update_storage.apply(eg_md.afd.is_worker,
            hdr, eg_md.afd.vlink_capacity, vlink_demand,
            eg_md.afd.vlink_id, eg_md.afd.new_threshold);
        //also handles recirc header setInvalid()
    }
}

Pipeline(SwitchIngressParser(),
         SwitchIngress(),
         SwitchIngressDeparser(),
         SwitchEgressParser(),
         SwitchEgress(),
         SwitchEgressDeparser()) pipe;

Switch(pipe) main;
