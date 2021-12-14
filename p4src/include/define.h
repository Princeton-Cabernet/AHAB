#pragma once

#define bytecount_t_width 32
#define byterate_t_width 32
#define NUM_VLINKS 4096
#define NUM_VTRUNKS 256
#define CMS_HEIGHT 2048

#define BYTERATE_T_SIGN_BIT 0x80000000
typedef bit<16> cms_index_t;
typedef bit<bytecount_t_width> bytecount_t;
typedef bit<byterate_t_width> byterate_t;
typedef bit<8> epoch_t;
typedef bit<16> vlink_index_t;
typedef bit<8> vtrunk_index_t;

typedef bit<5> exponent_t;

