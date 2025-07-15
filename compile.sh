#!/bin/sh

sbatch -N 1 -p rome --time 03:00:00 -w rome008     -o host.out compile_host.sh
sbatch -N 1 -p rome --time 03:00:00 -w romebf3a008 -o  dpu.out  compile_dpu.sh

