#!/usr/bin/env bash
cd build
cmake -DCMAKE_TOOLCHAIN_FILE=puya_toolchain.cmake ..
make
make flash