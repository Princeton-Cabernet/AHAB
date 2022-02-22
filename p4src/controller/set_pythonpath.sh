#!/bin/bash

PYVER=`python3 -c "import sys; print('%d.%d'%(sys.version_info[0],sys.version_info[1]))"`
INC1=$SDE/install/lib/python$PYVER/site-packages/tofino/bfrt_grpc/
INC2=$SDE/install/lib/python$PYVER/site-packages/tofino/

export PYTHONPATH=$INC1:$INC2:PYTHONPATH
