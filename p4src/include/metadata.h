#pragma once

#include "define.h"

@pa_auto_init_metadata
struct afd_metadata_t {
    packet_type_t           pkt_type;  // This has to be first
    epoch_t                 epoch;
    vlink_index_t           vlink_id;
    vtrunk_index_t          vtrunk_id;
    byterate_t              measured_rate;
    byterate_t              threshold;
    byterate_t              threshold_lo;
    byterate_t              threshold_hi;
    byterate_t              candidate_delta;      // 2**k
    exponent_t              candidate_delta_pow;  // k
    byterate_t              vtrunk_threshold;

    bytecount_t             scaled_pkt_len;
    bytecount_t             bytes_sent_lo;   // packet size for lo threshold simulation
    bytecount_t             bytes_sent_hi;   // packet size for hi threshold simulation
    bytecount_t             bytes_sent_all;  // packet size for total demand simulation

    byterate_t              new_threshold;
    bit<1>                  is_worker;  // Set by parser. Do not write in MATs
    bit<1>                  congestion_flag;
    bit<1>                  drop_withheld;
    byterate_t              max_rate;
}

@pa_auto_init_metadata
struct ig_metadata_t {
    afd_metadata_t afd;

    bit<16> sport;
    bit<16> dport;
}

@pa_auto_init_metadata
struct eg_metadata_t {
    afd_metadata_t afd;
}
