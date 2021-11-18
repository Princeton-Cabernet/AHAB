#!/bin/sh

./gen_include_files.py

bf-p4c --Wdisable=uninitialized_use afd.p4

if [ -n "$SDE_INSTALL" ]; then
	echo "Installing compiler output in $SDE_INSTALL"
	mv afd.tofino/afd.conf $SDE_INSTALL/share/p4/targets/tofino/afd.conf
	rm -rf $SDE_INSTALL/afd.tofino
	mv afd.tofino $SDE_INSTALL/
else
	echo "Var SDE_INSTALL not set. Not installing compiler output"
fi

