#pragma once

#include "define.h"

struct afd_metadata_t {
    epoch_t                 epoch;
    vlink_index_t           vlink_id;
    bytecount_t             scaled_pkt_len;
    bytecount_t             measured_rate;
    bytecount_t             threshold;
    bytecount_t             threshold_lo;
    bytecount_t             threshold_hi;
    bytecount_t             candidate_delta;      // 2**k
    exponent_t              candidate_delta_pow;  // k

    bytecount_t             bytes_sent_lo;
    bytecount_t             bytes_sent_hi;

    bytecount_t             threshold_new;
    bit<1>                  is_worker;
}

header perslice_md_t {
}
struct ig_metadata_t {
    afd_metadata_t afd;
    bit<16> sport;
    bit<16> dport;
}
struct eg_metadata_t {
}
