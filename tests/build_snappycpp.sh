#!/bin/sh

cd snappycpp
mkdir -p build
cd build
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ../

make snappy
cp libsnappy.a ../..
