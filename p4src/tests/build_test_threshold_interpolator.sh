#!/bin/sh

bf-p4c test_threshold_interpolator.p4

if [ -n "$SDE_INSTALL" ]; then
	echo "Installing compiler output in $SDE_INSTALL"
	sudo mv test_threshold_interpolator.tofino/*.conf $SDE_INSTALL/share/p4/targets/tofino/
	sudo rm -rf $SDE_INSTALL/test_threshold_interpolator.tofino
	sudo mv test_threshold_interpolator.tofino $SDE_INSTALL/
else
	echo "Var SDE_INSTALL not set. Not installing compiler output"
fi

