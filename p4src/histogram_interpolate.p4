// Approx UPF. Copyright (c) Princeton University, all rights reserved

#ifndef NUM_VLINKS
	#error "Please define NUM_VLINKS"
#endif


control Interpolate_Right(in bytecount_t Ch_minus_Cm, in bytecount_t new_C_minus_Cm, in bytecount_t Tm, in bit<8> T_gap_log, out bytecount_t new_T){
	//this calculates linear interpolation new_T=(new_C - Cm)/(Ch - Cm)*(1<<T2_T1_log) + Tm
	
	bit<5> shifted_numerator;//always <= denominator
	bit<5> shifted_denominator;//first bit always 1, use last 4 bits

	action rshift_4(){
		shifted_numerator=(bit<5>) new_C_minus_Cm>>4;
		shifted_denominator=(bit<5>) Ch_minus_Cm>>4;
	}
	action rshift_0(){
		shifted_numerator=(bit<5>) new_C_minus_Cm>>0;
		shifted_denominator=(bit<5>) Ch_minus_Cm>>0;
	}
	table tb_shiftscale{
		key={Ch_minus_Cm: ternary;}
		actions={rshift_4;rshift_0;}
		default_action=rshift_0();
		const entries={
			(32w0xffff0000 &&& 32w0xffff0000) : rshift_4();
			//todo
		}
	}

	action calc_new_T(bytecount_t offset){
		new_T=Tm+offset;
	}

	table tb_approx_div {
		key={
			shifted_numerator: exact;
			shifted_denominator: exact;
			T_gap_log: exact;//must fold this in to save a stage?
		}
		actions = {calc_new_T;}
		default_action=calc_new_T(0);
		const entries={
			(0,17,4):calc_new_T(0);
			(12,17,8):calc_new_T(180);// 
		}
	}

	apply{
		tb_shiftscale.apply();
		tb_approx_div.apply();
		//TODO
	}
}

control Interpolate_Left(in bytecount_t Cm_minus_Cl, in bytecount_t Cm_minus_new_C, in bytecount_t Tm, in bit<8> T_gap_log, out bytecount_t new_T){
	//this calculates linear interpolation new_T=Tm - (Cm - new_C)/(Cm - Cl)*(1<<T2_T1_log) 
	
	bit<5> shifted_numerator;//always <= denominator
	bit<5> shifted_denominator;//first bit always 1, use last 4 bits

	action rshift_4(){
		shifted_numerator=(bit<5>) Cm_minus_new_C>>4;
		shifted_denominator=(bit<5>) Cm_minus_Cl>>4;
	}
	action rshift_0(){
		shifted_numerator=(bit<5>) Cm_minus_new_C>>0;
		shifted_denominator=(bit<5>) Cm_minus_Cl>>0;
	}
	table tb_shiftscale{
		key={Cm_minus_Cl: ternary;}
		actions={rshift_4;rshift_0;}
		default_action=rshift_0();
		const entries={
			(32w0xffff0000 &&& 32w0xffff0000) : rshift_4();
			//todo
		}
	}

	action calc_new_T(bytecount_t offset){
		new_T=Tm-offset; //LHS uses minus
	}

	table tb_approx_div {
		key={
			shifted_numerator: exact;
			shifted_denominator: exact;
			T_gap_log: exact;//must fold this in to save a stage?
		}
		actions = {calc_new_T;}
		default_action=calc_new_T(0);
		const entries={
			(0,17,4):calc_new_T(0);
			(12,17,8):calc_new_T(180);// 
		}
	}

	apply{
		tb_shiftscale.apply();
		tb_approx_div.apply();
		//TODO
	}
}



control Get_Neighbouring_Slice(in bytecount_t mid_slice_thres, out bytecount_t low_slice_thres, out bytecount_t high_slice_thres, out bit<8> log_offset){
		action calc_thres_0(){
		log_offset=0;
		bytecount_t diff = 1<< 0;
		low_slice_thres=mid_slice_thres - diff;
		high_slice_thres=mid_slice_thres + diff;
	}
	action calc_thres_4(){
		log_offset=4;
		bytecount_t diff = 1<< 4;
		low_slice_thres=mid_slice_thres - diff;
		high_slice_thres=mid_slice_thres + diff;
	}
	action calc_thres_8(){
		log_offset=8;
		bytecount_t diff = 1<< 8;
		low_slice_thres=mid_slice_thres - diff;
		high_slice_thres=mid_slice_thres + diff;
	}
	action calc_thres_12(){
		log_offset=16;
		bytecount_t diff = 1<< 12;
		low_slice_thres=mid_slice_thres - diff;
		high_slice_thres=mid_slice_thres + diff;
	}
	action calc_thres_16(){
		log_offset=16;
		bytecount_t diff = 1<< 16;
		low_slice_thres=mid_slice_thres - diff;
		high_slice_thres=mid_slice_thres + diff;
	}
	table tb_calc_thres{
		key={mid_slice_thres: ternary;}
		actions={
			calc_thres_0;
			calc_thres_4;
			calc_thres_8;
			calc_thres_12;
			calc_thres_16;
		}
		default_action=calc_thres_0;
		const entries = {
			(32w0x0 &&& 32w0xfffffff0): calc_thres_0();//<=16^1
			(32w0x0 &&& 32w0xffffff00): calc_thres_4();//<=16^2
			(32w0x0 &&& 32w0xffffff00): calc_thres_8();//<=16^3
			(32w0x0 &&& 32w0xfffff000): calc_thres_12();//<=16^4
			(32w0x0 &&& 32w0xffff0000): calc_thres_16();//<=16^5
			//need better rules
		}
	}
	apply{
		tb_calc_thres.apply();
	}
}

// Remember the number of total bytes send below the threshold line slice_thres
// ech slicing line is a horizontal line on the histogram 
control Histogram_Three_Slice(
		in vlink_index_t index,
		in bytecount_t my_flow_size,
		in bytecount_t my_pkt_size,
		in bytecount_t mid_slice_thres,
		in bytecount_t low_slice_thres,
		in bytecount_t high_slice_thres,
		in bit<8> log_offset,
		//in bytecount_t slice_offset,
		in bool is_readout,
		// if readout, interpolate
		in bytecount_t new_C,
		out bytecount_t new_T
	){

	Register<bytecount_t, vlink_index_t>(NUM_VLINKS) middle_slice;
	Register<bytecount_t, vlink_index_t>(NUM_VLINKS) higher_slice;
	Register<bytecount_t, vlink_index_t>(NUM_VLINKS) lower_slice;

	RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(middle_slice) write_if_exceed_middle = {
		void apply(inout bytecount_t stored_count, out bytecount_t rv) {
			//if(my_flow_size < mid_slice_thres){
				stored_count=stored_count+my_pkt_size; 
			//}
    	}
	};

	RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(lower_slice) write_if_exceed_lower = {
		void apply(inout bytecount_t stored_count, out bytecount_t rv) {
			//if(my_flow_size < low_slice_thres){
				stored_count=stored_count+my_pkt_size; 
			//}
    	}
	};

	RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(higher_slice) write_if_exceed_higher = {
		void apply(inout bytecount_t stored_count, out bytecount_t rv) {
			//if(my_flow_size < high_slice_thres){
				stored_count=stored_count+my_pkt_size; 
			//}
    	}
	};


	RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(middle_slice) read_and_clean_middle = {
		void apply(inout bytecount_t stored_count, out bytecount_t rv) {
			rv=stored_count;
			stored_count=0;
    	}
	};
	RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(lower_slice) read_and_clean_lower = {
		void apply(inout bytecount_t stored_count, out bytecount_t rv) {
			rv=stored_count;
			stored_count=0;
    	}
	};
	RegisterAction<bytecount_t, vlink_index_t, bytecount_t>(higher_slice) read_and_clean_higher = {
		void apply(inout bytecount_t stored_count, out bytecount_t rv) {
			rv=stored_count;
			stored_count=0;
    	}
	};

	Interpolate_Right() interpolate_r;
	Interpolate_Right() interpolate_l;

	bytecount_t Cm;
	bytecount_t Ch;
	bytecount_t Cl;
	bytecount_t dCm;
	bytecount_t dCl;
	bytecount_t dCh;
	action calc_new_C_diff(){
		dCm= Cm - new_C;
		dCl= Ch - new_C;
		dCh= Cl - new_C;
	}//wrap in action, force split

	bytecount_t dTm;
	bytecount_t dTl;
	bytecount_t dTh;
	action calc_T_diff(){
		dTm = mid_slice_thres - my_flow_size;
		dTh = high_slice_thres - my_flow_size;
		dTl = low_slice_thres - my_flow_size;
	}

	apply{
		calc_T_diff();//hoisted to smooth control-flow analysis

		if(is_readout){
			//read and clean.
			Cm=read_and_clean_middle.execute(index);
			Cl=read_and_clean_lower.execute(index);
			Ch=read_and_clean_higher.execute(index);
			calc_new_C_diff();

			//precalculate diffs for interpolate
			bytecount_t Ch_minus_Cm=Ch-Cm;
			bytecount_t new_C_minus_Cm=new_C-Cm;
			bytecount_t Cm_minus_Cl=Cm-Cl;
			bytecount_t Cm_minus_new_C=Cm-new_C;

			//check sign bit
			bit<1> sb_dCm=dCm[(bytecount_t_width-1):(bytecount_t_width-1)];
			bit<1> sb_dCh=dCh[(bytecount_t_width-1):(bytecount_t_width-1)];
			bit<1> sb_dCl=dCl[(bytecount_t_width-1):(bytecount_t_width-1)];

			bool Cm_lt_new_C = (sb_dCm == 1w1);
			bool Ch_lt_new_C = (sb_dCh == 1w1);
			bool Cl_lt_new_C = (sb_dCl == 1w1);
			if(Ch_lt_new_C){//Ch<new_C
				new_T=high_slice_thres;//return Th
			}else if(Cm_lt_new_C){// Cm < new_C <= Ch
				interpolate_r.apply(Ch_minus_Cm,new_C_minus_Cm,mid_slice_thres,log_offset,   new_T);//interpolate
			}else if(Cl_lt_new_C){// Cl < new_C <= Cm
				interpolate_l.apply(Cm_minus_Cl,Cm_minus_new_C,mid_slice_thres,log_offset,   new_T);
			}else{// new_C < Cl
				new_T=low_slice_thres;//return Tl
			}
		}else{
			//just add to the slice line, if my size is above the threshold slice
			// calc_T_diff();//hoisted out

			//check sign bit
			bit<1> sb_dTm=dTm[(bytecount_t_width-1):(bytecount_t_width-1)];
			bit<1> sb_dTh=dTh[(bytecount_t_width-1):(bytecount_t_width-1)];
			bit<1> sb_dTl=dTl[(bytecount_t_width-1):(bytecount_t_width-1)];

			bool midT_lt_myflowsize = (sb_dTm == 1w1);
			bool highT_lt_myflowsize = (sb_dTh == 1w1);
			bool lowT_lt_myflowsize = (sb_dTl == 1w1);

			if(! midT_lt_myflowsize){//this flow is under the middle threshold line, add to capacity demand estimate of middle C
				write_if_exceed_middle.execute(index);
			}
			if(! highT_lt_myflowsize){
				write_if_exceed_higher.execute(index);
			}
			if(! lowT_lt_myflowsize){
				write_if_exceed_lower.execute(index);
			}
		}
	}
}