#pragma once

#include "define.h"

header afd_recirc_metadata_t {
    bytecount_t             new_fair_rate;
    vlink_index_t           vlink_id;  // Only set immediately before recirculation, don't read elsewhere
}

header afd_bridged_metadata_t {
    bytecount_t             lo_bytes_to_send;
    bytecount_t             hi_bytes_to_send;
    bytecount_t             scaled_pkt_len;
    vlink_index_t           vlink_id;
    bytecount_t             fair_rate;
    bytecount_t             fair_rate_lo;
    bytecount_t             fair_rate_hi;
    bytecount_t             candidate_delta;       // 2**k
    bytecount_t             candidate_delta_pow;  // k
}

struct afd_metadata_t {
    afd_bridged_metadata_t  bridged;
    afd_recirc_metadata_t   recircd;

    bytecount_t             measured_rate;
    bit<1>                  is_worker;
}

header perslice_md_t {
}
struct ig_metadata_t {
}
struct eg_metadata_t {
}
