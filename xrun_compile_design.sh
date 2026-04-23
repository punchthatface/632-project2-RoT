#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

xrun -clean
xrun -compile -timescale 1ns/1ps -access +rwc -f xrun_design.f

cat <<'EOF'
Design files compiled into xcelium.d/worklib with waveform read access.

Run a graded testbench directly with:
  xrun tb/tb_f1.sv

If you change any design file, rerun:
  ./xrun_compile_design.sh
EOF
