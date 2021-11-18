// Approx UPF. Copyright (c) Princeton University, all rights reserved

control RateEstimator(in bit<32> src_ip,
                      in bit<32> dst_ip,
                      in bit<8> proto,
                      in bit<16> src_port,
                      in bit<16> dst_port,
                      in  bytecount_t sketch_input,
                      out byterate_t sketch_output) {

    Lpf<bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_1;
    Lpf<bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_2;
    Lpf<bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_3;


    byterate_t cms_output_1;
    byterate_t cms_output_2;
    byterate_t cms_output_3;


    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_1;
    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_2;
    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_3;

    cms_index_t index1;
    cms_index_t index2;
    cms_index_t index3;

    bit<1> dummy_bit = 0;

    @hidden
    action read_cms_act1() {
        index1 = hash_1.get({ src_ip,
                             dst_ip,
                             proto,
                             src_port,
                             dst_port});
        cms_output_1 = (byterate_t) lpf_1.execute(sketch_input, index1);
    }
    @hidden
    action read_cms_act2() {
        index2 = hash_2.get({ src_ip,
                             3w0,
                             dst_ip,
                             3w0,
                             proto,
                             src_port,
                             dst_port});
        cms_output_2 = (byterate_t) lpf_2.execute(sketch_input, index2);
    }
    @hidden
    action read_cms_act3() {
        index3 = hash_3.get({ src_ip,
                             dst_ip,
                             2w0,
                             proto,
                             2w0,
                             src_port,
                             1w0,
                             dst_port});
        cms_output_3 = (byterate_t) lpf_3.execute(sketch_input, index3);
    }

    @hidden
    table cms_tbl1 {
        key = { dummy_bit: exact; }
        actions = { read_cms_act1; }
        const entries = { 0 : read_cms_act1(); }
        size = 1;
    }
    @hidden
    table cms_tbl2 {
        key = { dummy_bit: exact; }
        actions = { read_cms_act2; }
        const entries = { 0 : read_cms_act2(); }
        size = 1;
    }
    @hidden
    table cms_tbl3 {
        key = { dummy_bit: exact; }
        actions = { read_cms_act3; }
        const entries = { 0 : read_cms_act3(); }
        size = 1;
    }



    apply {
        // Get CMS indices
        cms_tbl1.apply();
        cms_tbl2.apply();
        cms_tbl3.apply();

        // Get the minimum of all register contents
        sketch_output = min<byterate_t>(cms_output_1, cms_output_2);
        sketch_output = min<byterate_t>(sketch_output, cms_output_3);
    }
}
