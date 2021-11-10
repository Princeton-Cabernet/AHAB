// Approx UPF. Copyright (c) Princeton University, all rights reserved

control VLink_Find(in header_t hdr, out vlink_index_t vlink_index, out bytecount_t scaled_weight){

	action set_vlink_shift1(vlink_index_t i){
		vlink_index=i;
		scaled_weight=(bytecount_t) (hdr.ipv4.total_len << 1);
	}
	action set_vlink_shift2(vlink_index_t i){
		vlink_index=i;
		scaled_weight=(bytecount_t) (hdr.ipv4.total_len << 2);
	}
	action set_vlink_shift3(vlink_index_t i){
		vlink_index=i;
		scaled_weight=(bytecount_t) (hdr.ipv4.total_len << 3);
	}
	action set_vlink_shift4(vlink_index_t i){
		vlink_index=i;
		scaled_weight=(bytecount_t) (hdr.ipv4.total_len << 4);
	}
	action set_vlink_shift5(vlink_index_t i){
		vlink_index=i;
		scaled_weight=(bytecount_t) (hdr.ipv4.total_len << 5);
	}
	action set_vlink_shift6(vlink_index_t i){
		vlink_index=i;
		scaled_weight=(bytecount_t) (hdr.ipv4.total_len << 6);
	}


	action set_vlink_default(){
		//demo: just use the 3rd segment of ip dst
		bit<16> ip_seg = hdr.ipv4.dst_addr[15:0] >> 8;
		vlink_index=(vlink_index_t) ip_seg;
		//also just scale the same for everyone
		scaled_weight=(bytecount_t) (hdr.ipv4.total_len << 0);
	}
	table tb_match_ip{
		key = {hdr.ipv4.dst_addr: ternary;}
		actions = {
			set_vlink_shift1;
			set_vlink_shift2;
			set_vlink_shift3;
			set_vlink_shift4;
			set_vlink_shift5;
			set_vlink_shift6;
			set_vlink_default;
		}
		default_action = set_vlink_default();
		size = 1024;
		const entries = {
			(32w0xffff0000 &&& 32w0xffff0000): set_vlink_shift1(3);
		}
	}

	apply {
		tb_match_ip.apply();
	}
}