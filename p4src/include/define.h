#pragma once

#define bytecount_t_width 32
#define byterate_t_width 32
#define NUM_VLINKS 1024
#define CMS_HEIGHT 2048

typedef bit<16> cms_index_t;
typedef bit<bytecount_t_width> bytecount_t;
typedef bit<byterate_t_width> byterate_t;
typedef bit<8> epoch_t;
typedef bit<16> vlink_index_t;

typedef bit<5> exponent_t;


// Desired scaled bytes per second for each vlink (scaled bytes is bytes divided by vlink weight)
const bytecount_t DESIRED_VLINK_RATE = 65000;

