#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <tb-file>"
  echo "Example: $0 tb/tb_f1.sv"
  exit 1
fi

cd "$(dirname "$0")"

tb_file="$1"

xrun -timescale 1ns/1ps -f xrun_design.f "$tb_file"
