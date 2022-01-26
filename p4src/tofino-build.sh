#!/bin/sh

if ./gen_include_files.py; then
	echo "Generated include files"
else
	echo "Include file generation failed."
	exit 1
fi


if bf-p4c --Wdisable=uninitialized_use afd.p4; then
	echo "Compilation succeeded"
else
	echo "Compilation failed"
	exit 1
fi

if [ -n "$SDE_INSTALL" ]; then
	echo "Installing compiler output in $SDE_INSTALL"
	sudo mv afd.tofino/afd.conf $SDE_INSTALL/share/p4/targets/tofino/afd.conf
	sudo rm -rf $SDE_INSTALL/afd.tofino
	sudo mv afd.tofino $SDE_INSTALL/
else
	echo "Var SDE_INSTALL not set. Not installing compiler output"
fi

