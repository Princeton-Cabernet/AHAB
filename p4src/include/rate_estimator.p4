/*
    AHAB project
    Copyright (c) 2022, Robert MacDavid, Xiaoqi Chen, Princeton University.
    macdavid [at] cs.princeton.edu
    License: AGPLv3
*/

// Estimate per-flow rate using 3-row CMS-LPF estimator
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

    byterate_t cms_output_1_;
    byterate_t cms_output_2_;
    byterate_t cms_output_3_;

    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_1;
    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_2;
    Hash<cms_index_t>(HashAlgorithm_t.CRC16) hash_3;

    action read_cms_act1_() {
        cms_output_1_ = (byterate_t) lpf_1.execute(sketch_input, 
                                                   hash_1.get({ src_ip,
                                                                dst_ip,
                                                                proto,
                                                                src_port,
                                                                dst_port}));
    }
    action read_cms_act2_() {
        cms_output_2_ = (byterate_t) lpf_2.execute(sketch_input,
                                                   hash_2.get({ src_ip,
                                                                3w0,
                                                                dst_ip,
                                                                3w0,
                                                                proto,
                                                                src_port,
                                                                dst_port}));
    }
    action read_cms_act3_() {
        cms_output_3_ = (byterate_t) lpf_3.execute(sketch_input,
                                                   hash_3.get({ src_ip,
                                                                dst_ip,
                                                                2w0,
                                                                proto,
                                                                2w0,
                                                                src_port,
                                                                1w0,
                                                                dst_port}));
    }

    apply {
        read_cms_act1_();
        read_cms_act2_();
        read_cms_act3_();

        // Get the minimum of all register contents
        sketch_output = min<byterate_t>(cms_output_1_, cms_output_2_);
        sketch_output = min<byterate_t>(sketch_output, cms_output_3_);
    }
}
