#pragma once

#include "define.h"

@pa_auto_init_metadata
struct afd_metadata_t {
    epoch_t                 epoch;
    vlink_index_t           vlink_id;
    bytecount_t             scaled_pkt_len;
    byterate_t              measured_rate;
    byterate_t              threshold;
    byterate_t              threshold_lo;
    byterate_t              threshold_hi;
    byterate_t              candidate_delta;      // 2**k
    exponent_t              candidate_delta_pow;  // k

    bytecount_t             bytes_sent_lo;
    bytecount_t             bytes_sent_hi;

    byterate_t              new_threshold;
    bit<1>                  is_worker;
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
