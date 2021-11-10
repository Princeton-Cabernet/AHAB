#include <core.p4>
#include <tna.p4>

#include "include/headers.p4"
#include "include/util.p4"

#define CMS_HEIGHT 65536

control DecayingCountMinSketch(in  flow_bytecount_t sketch_input,
                     out flow_bytecount_t sketch_output,
                     in header_t hdr,
                     in ig_metadata_t ig_md) {

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
        index1 = hash1.get({ hdr.ipv4.proto,
                             hdr.ipv4.sip,
                             hdr.ipv4.dip,
                             ig_md.sport,
                             ig_md.dport });
        index2 = hash2.get({ hdr.ipv4.proto,
                             hdr.ipv4.sip,
                             hdr.ipv4.dip,
                             ig_md.sport,
                             ig_md.dport });
        index3 = hash3.get({ hdr.ipv4.proto,
                             hdr.ipv4.sip,
                             hdr.ipv4.dip,
                             ig_md.sport,
                             ig_md.dport });

        // Get register contents
        cms_output_1 = lpf_1.execute(sketch_input, index1);
        cms_output_2 = lpf_2.execute(sketch_input, index2);
        cms_output_3 = lpf_3.execute(sketch_input, index3);

        // Get the minimum of all register contents
        sketch_output = min<bit<16>>(cms_output_1, cms_output_2);
        sketch_output = min<bit<16>>(sketch_output, cms_output_3);
    }
}
