#!/usr/bin/env bash
# Build the CVA6 CV-X-IF stale-writeback PoCs and run them.
#   ./repro.sh               build (if needed), run both PoCs
#   ./repro.sh fence         ... only the fence PoC        (prog_fence.S)
#   ./repro.sh buserr        ... only the bus-error PoC    (prog_buserr.S)
#   ./repro.sh -b            only build (sim + programs)
#   ./repro.sh -w            ... and dump FSDB into waves/
#
# Requires VCS and riscv64-unknown-elf-* on PATH.
set -e
cd "$(dirname "$0")"

CC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy
CFLAGS="-march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles -mcmodel=medany"

# bus-error injection knobs (prog_buserr.S): the testbench holds the read at
# 0x4000_0000 for ERR_LAT cycles, then answers rresp=SLVERR.  6 cycles puts
# the exception flush inside the offload's 40-cycle flight window but before
# the trap handler drains, so the stale result (old trans_id 3) lands in the
# re-issued `addi s3` (slot 3) -> R_S3 = 1 instead of 306.
ERR_ADDR=40000000
ERR_LAT=6

# site fallbacks (override with your own env if these differ)
[ -z "$VCS_HOME" ] && [ -d /eda/tool/synopsys/vcs/X-2025.06-1 ] && export VCS_HOME=/eda/tool/synopsys/vcs/X-2025.06-1
[ -z "$LM_LICENSE_FILE" ] && [ -f /eda/tool/synopsys/Synopsys.dat ] && export LM_LICENSE_FILE=/eda/tool/synopsys/Synopsys.dat
VERDI_HOME=${VERDI_HOME:-/eda/tool/synopsys/verdi/X-2025.06-1}

build_sim() {
  local novas=""
  [ -f "$VERDI_HOME/share/PLI/VCS/linux64/novas.tab" ] && \
    novas="-P $VERDI_HOME/share/PLI/VCS/linux64/novas.tab $VERDI_HOME/share/PLI/VCS/linux64/pli.a"
  python3 gen_filelist.py
  vcs -full64 +vcs+lic+wait -sverilog -timescale=1ns/1ps -debug_access+all \
      $novas \
      +incdir+$(cd ../../core/include && pwd) \
      -f filelist.f tb_cva6_cvxif.sv -top tb_cva6_cvxif -o simv > vcs.log 2>&1 \
    || { echo "VCS build FAILED (see vcs.log)"; exit 1; }
}

build_prog() {
  $CC $CFLAGS -T link.ld -o prog_$1.elf prog_$1.S
  $OBJCOPY -O binary prog_$1.elf prog_$1.bin
  python3 gen_hex.py prog_$1.bin prog_$1.hex >/dev/null
}

POCS="fence buserr"
BUILD_ONLY=0
W=""
while [ $# -gt 0 ]; do
  case "$1" in
    fence|buserr) POCS="$1" ;;
    -b) BUILD_ONLY=1 ;;
    -w) mkdir -p waves; W="+wave=waves/run.fsdb" ;;
    *)  echo "usage: $0 [fence|buserr] [-b|-w]"; exit 1 ;;
  esac
  shift
done

[ -x ./simv ] || build_sim
for p in $POCS; do build_prog $p; done
[ $BUILD_ONLY = 1 ] && exit 0

run_one() {
  local extra=""
  [ "$1" = buserr ] && extra="+err_addr=$ERR_ADDR +err_lat=$ERR_LAT"
  ./simv +mem=prog_$1.hex +dump=dump_$1.txt +trace=1 +max_cycles=80000 $extra $W > run_$1.log 2>&1 || true
  echo "----- $1 -----"
  grep -E "^CVXIF|^BUSERR|^FLUSH|^WB ACCEPT|^DONE|^TIMEOUT|^CFG" run_$1.log | head -40
  echo
  [ -f dump_$1.txt ] && sed 's/^/  /' dump_$1.txt
  echo
}

for p in $POCS; do run_one $p; done

cat <<'EOF'
  expect: the offload is issued TWICE (same instr, the flush squashed it and
  it was refetched), and the first execution's result returns after the flush
  with the OLD trans_id.  The scoreboard accepts it into the slot that now
  belongs to an unrelated addi, which then retires with the stale value (1)
  instead of 106/206/306.
EOF
