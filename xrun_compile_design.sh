#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

xrun -compile -timescale 1ns/1ps -f xrun_design.f

cat <<'EOF'
Design files compiled into xcelium.d/worklib.

You can now run a testbench with just:
  xrun -timescale 1ns/1ps tb/tb_f1.sv

If you change any design file, rerun:
  ./xrun_compile_design.sh
EOF
