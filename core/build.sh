#!/bin/bash

SOURCE="src"
OUTPUT="riscbox"

MODE="dev"
if [[ $1 == "d" ]]; then MODE="debug"; fi
if [[ $1 == "r" ]]; then MODE="release"; fi

TARGET="linux_amd64"
if [[ $1 == "-target" ]]; then TARGET=$2; fi
if [[ $2 == "-target" ]]; then TARGET=$3; fi

COMMON="-no-dynamic-literals"
if [[ $MODE == "dev"     ]]; then FLAGS="-o:none -use-separate-modules"; fi
if [[ $MODE == "debug"   ]]; then FLAGS="-o:none -debug"; fi
if [[ $MODE == "release" ]]; then FLAGS="-o:speed -vet -no-bounds-check -no-type-assert"; fi

echo [package:$OUTPUT]
echo [target:$TARGET]
echo [mode:$MODE]

if [[ ! -d "out" ]]; then mkdir out; fi
odin build $SOURCE -out:out/$OUTPUT -target:$TARGET $FLAGS $COMMON -collection:src=src
