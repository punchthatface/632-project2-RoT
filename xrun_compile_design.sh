#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

xrun -clean
xrun -compile -timescale 1ns/1ps -f xrun_design.f

cat <<'EOF'
Design files compiled into xcelium.d/worklib.

Because the testbenches currently `include "rot_pkg.sv"`, the most reliable
way to run a testbench is through the wrapper below so xrun can keep package
checksums consistent:
  ./xrun_run_tb.sh tb/tb_f1.sv

If you change any design file, rerun:
  ./xrun_compile_design.sh
EOF
