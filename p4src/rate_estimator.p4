// Approx UPF. Copyright (c) Princeton University, all rights reserved

control RateEstimator(in bit<32> src_ip,
                      in bit<32> dst_ip,
                      in bit<8> proto,
                      in bit<16> src_port,
                      in bit<16> dst_port,
                      in  flow_bytecount_t sketch_input,
                      out flow_bytecount_t sketch_output) {

    Lpf<flow_bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_1;
    Lpf<flow_bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_2;
    Lpf<flow_bytecount_t, cms_index_t>(size=CMS_HEIGHT) lpf_3;


    flow_bytecount_t cms_output_1;
    flow_bytecount_t cms_output_2;
    flow_bytecount_t cms_output_3;


    Hash<cms_index_t>(HashAlgorithm_t.CRC_16) hash_1;
    Hash<cms_index_t>(HashAlgorithm_t.CRC_16) hash_2;
    Hash<cms_index_t>(HashAlgorithm_t.CRC_16) hash_3;

    cms_index_t index1;
    cms_index_t index2;
    cms_index_t index3;


    apply {
        // Get CMS indices
        index1 = hash1.get({ src_ip,
                             dst_ip,
                             proto,
                             src_port,
                             dst_port});
        index2 = hash2.get({ src_ip,
                             3w0,
                             dst_ip,
                             3w0,
                             proto,
                             src_port,
                             dst_port});
        index3 = hash3.get({ src_ip,
                             dst_ip,
                             2w0,
                             proto,
                             2w0
                             src_port,
                             1w0
                             dst_port});

        // Get register contents
        cms_output_1 = lpf_1.execute(sketch_input, index1);
        cms_output_2 = lpf_2.execute(sketch_input, index2);
        cms_output_3 = lpf_3.execute(sketch_input, index3);

        // Get the minimum of all register contents
        sketch_output = min<bit<16>>(cms_output_1, cms_output_2);
        sketch_output = min<bit<16>>(sketch_output, cms_output_3);
    }
}
