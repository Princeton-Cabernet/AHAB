#pragma once

// An I2E mirror session that mirrors packets to the recirculation port
// Must be installed by the control plane before it will work!
#define THRESHOLD_UPDATE_MIRROR_SESSION  10w50

#define bytecount_t_width 32
#define byterate_t_width 32
#define NUM_VLINKS 4096
#define NUM_VLINK_GROUPS 256
#define CMS_HEIGHT 4096
#define DEFAULT_VLINK_CAPACITY 6450
// capacity 8192 -> 125Mbps

#define DEFAULT_THRESHOLD 1024

#define BYTERATE_T_SIGN_BIT 0x80000000
typedef bit<11> cms_index_t;
typedef bit<bytecount_t_width> bytecount_t;
typedef bit<byterate_t_width> byterate_t;
typedef bit<8> epoch_t;
typedef bit<16> vlink_index_t;

typedef bit<8> exponent_t;


typedef bit<8> bridged_metadata_type_t;
const bridged_metadata_type_t BMD_TYPE_INVALID = 0;
const bridged_metadata_type_t BMD_TYPE_I2E = 0xa;
const bridged_metadata_type_t BMD_TYPE_MIRROR = 2;

typedef bit<3> mirror_type_t;
const mirror_type_t MIRROR_TYPE_INVALID = 0;
const mirror_type_t MIRROR_TYPE_I2E = 1;

