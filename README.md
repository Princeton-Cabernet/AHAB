
# AHAB: Scalable Real-Time Bandwidth Fairness in Switches

This repository hosts the prototype implementation of our INFOCOM 2023 paper [Scalable Real-Time Bandwidth Fairness in Switches](#TBD). 

The `p4src` directory contains the P4 program source code, as well as the corresponding control-plane scripts. The `python` directory holds source code for our simulation.

## Structure

Our P4 program contains the following submodules.

Ingress:

- `vlink_lookup.p4` maps a user (5-tuple) into a particular slice and look up the corresponding per-user rate threshold, as well as routes it to the corresponding egress port. It also applies weighting and normalize the packet size.
	- By default, the suffix of destination IP becomes the slice ID (`vlink_id`), which is also the routing egress port. You can override by adding table rules from the control plane.
- `worker_generator.p4` is responsible for generating one worker packet per epoch for each slice. The worker packet then performs the interpolation-based update.
- `rate_estimator.p4` uses CMS-LPF arrays to estimate the per-user sending rate.
- `rate_enforcer.p4` compares the estimated sending rate against the rate threshold, and if necessary, uses randomized dropping (UDP) or countdown-based dropping (TCP) to enforce the rate limit. It also generates two hypothetical dropping decision for higher and lower thresholds.
- `byte_dumps.p4` helps accurately record the actual and hypothetical sending rate at each threshold candidate. It temporarily stashes a packet's size if the packet will be dropped, and report the size using a subsequent non-dropped packet.

Egress:
- `link_rate_tracker.p4` uses LPF to estimate the total bandwidth demand for a slice, as well as the actual and hypothetical sending rates given the candidate thresholds.
- `threshold_interpolator.p4` performs approximate linear interpolation based on these estimated sending rates, to calculate a new threshold that best matches the slice's capacity.
- `update_storage.p4` temporarily saves the new threshold for the next epoch, waiting for a worker packet to perform message passing back to the beginning of the ingress pipeline.

## Building and Running

The P4 program can be built with `bf-sde` version 9.7 or above. The file `define.h` includes various constants such as the number of slices (vlinks) supported and the default total bandwidth available per slice; you may change it before compilation if needed. Please run the following script to build, install, and run the program:
```
cd p4src/
./tofino-build.sh
$SDE/run_switchd.sh -p afd
```

The control plane consists of various individual scripts for adding table rules and maintaining thresholds. The most basic setup sets a constant total capacity (100Mbps) for all slices, and requires adding mirror session, setting LPF constants, and adding rules for interpolation range. Please run the following script to add these control plane rules.
```
cd p4src/controller/
./default_settings.sh
``` 

## Citation

If you find the code useful, please consider citing:

	@article{macdavid2023AHAB,
		title={Scalable Real-Time Bandwidth Fairness in Switches},
		author={MacDavid, Robert and Chen, Xiaoqi and Rexford, Jennifer},
		journal={IEEE INFOCOM 2023}, 
		year={2023},
		publisher={IEEE}
	}


## License
Copyright 2022 Robert MacDavid, Xiaoqi Chen, Princeton University.

The project source code, including the P4 data plane program and the accompanying control plane, is released under the **[GNU Affero General Public License v3](https://www.gnu.org/licenses/agpl-3.0.html)**. 

If you modify the code and make the functionality of the code available to users interacting with it remotely through a computer network, for example through a P4 program, you must make the modified source code freely available under the same AGPLv3 license.
