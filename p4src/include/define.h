#pragma once

#define bytecount_t_width 32
#define byterate_t_width 32
#define NUM_VLINKS 4096
#define NUM_VTRUNKS 256
#define CMS_HEIGHT 2048
#define DEFAULT_VLINK_CAPACITY 8192
#define DEFAULT_THRESHOLD 1024

#define BYTERATE_T_SIGN_BIT 0x80000000
typedef bit<16> cms_index_t;
typedef bit<bytecount_t_width> bytecount_t;
typedef bit<byterate_t_width> byterate_t;
typedef bit<8> epoch_t;
typedef bit<16> vlink_index_t;
typedef bit<8> vtrunk_index_t;

typedef bit<5> exponent_t;


typedef bit<8> packet_type_t;
const packet_type_t PKT_TYPE_NORMAL = 0;
const packet_type_t PKT_TYPEMIRROR = 1;


#if __TARGET_TOFINO__ == 1
typedef bit<3> mirror_type_t;
#else
typedef bit<4> mirror_type_t;
#endif
const mirror_type_t MIRROR_TYPE_I2E = 1;
const mirror_type_t MIRROR_TYPE_E2E = 2;
