#pragma once

#define bytecount_t_width 32
#define NUM_VLINKS 1024
#define CMS_HEIGHT 2048

typedef bit<16> cms_index_t;
typedef bit<bytecount_t_width> bytecount_t;
typedef bit<8> epoch_t;
typedef bit<16> vlink_index_t;


// maximum per-slice bytes sent per-window. Should be base station bandwidth * window duration
const bytecount_t FIXED_VLINK_CAPACITY = 65000;

