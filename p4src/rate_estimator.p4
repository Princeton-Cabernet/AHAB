// Approx UPF. Copyright (c) Princeton University, all rights reserved

control RateEstimator(in bit<32> src_ip,
                      in bit<32> dst_ip,
                      in bit<8> proto,
                      in bit<16> src_port,
                      in bit<16> dst_port,
                      in  bytecount_t sketch_input,
                      out bytecount_t sketch_output) {

    Lpf<bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_1;
    Lpf<bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_2;
    Lpf<bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_3;


    bytecount_t cms_output_1;
    bytecount_t cms_output_2;
    bytecount_t cms_output_3;


    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_1;
    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_2;
    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_3;

    cms_index_t index1;
    cms_index_t index2;
    cms_index_t index3;

bit<1> dummy_bit = 0;

action hash1_act() {
        index1 = hash_1.get({ src_ip,
                             dst_ip,
                             proto,
                             src_port,
                             dst_port});
        cms_output_1 = lpf_1.execute(sketch_input, index1);
}
action hash2_act() {
        index2 = hash_2.get({ src_ip,
                             3w0,
                             dst_ip,
                             3w0,
                             proto,
                             src_port,
                             dst_port});
        cms_output_2 = lpf_2.execute(sketch_input, index2);
}
action hash3_act() {
        index3 = hash_3.get({ src_ip,
                             dst_ip,
                             2w0,
                             proto,
                             2w0,
                             src_port,
                             1w0,
                             dst_port});
        cms_output_3 = lpf_3.execute(sketch_input, index3);
}

table hash1_tbl {
    key = { dummy_bit: exact; }
    actions = { hash1_act; }
    const entries = { 0 : hash1_act(); }
    size = 1;
}
table hash2_tbl {
    key = { dummy_bit: exact; }
    actions = { hash2_act; }
    const entries = { 0 : hash2_act(); }
    size = 1;
}
table hash3_tbl {
    key = { dummy_bit: exact; }
    actions = { hash3_act; }
    const entries = { 0 : hash3_act(); }
    size = 1;
}



    apply {
        // Get CMS indices
        hash1_tbl.apply();
        hash2_tbl.apply();
        hash3_tbl.apply();

        // Get register contents
        //cms_output_1 = lpf_1.execute(sketch_input, index1);
        //cms_output_2 = lpf_2.execute(sketch_input, index2);
        //cms_output_3 = lpf_3.execute(sketch_input, index3);

        // Get the minimum of all register contents
        sketch_output = min<bytecount_t>(cms_output_1, cms_output_2);
        sketch_output = min<bytecount_t>(sketch_output, cms_output_3);
    }
}
