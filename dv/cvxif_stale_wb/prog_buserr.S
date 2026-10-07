# -----------------------------------------------------------------------------
# prog_buserr.S -- CVA6 CV-X-IF stale-result testcase (bus-error variant)
#
# Same stale-writeback race as prog_fence.S, but the flush source is a read
# bus error injected on the core's top-level AXI port instead of a `fence`:
# the testbench holds the read below for +err_lat cycles and then answers it
# with rresp = SLVERR.
#
#  1. `lw t4, 0(t5)` targets an address outside every memory-region rule
#     (0x4000_0000), so it travels to the AXI port as an uncacheable
#     single-beat transaction and sits in the LSU while the testbench delays
#     the error response.
#  2. `custom0 a0, t1, t2` behind it is issued *while the load is still
#     outstanding* (out-of-order issue); the offload is committed to the
#     coprocessor with `commit_kill = 0` and can no longer be cancelled.
#  3. The SLVERR arrives and raises a precise HARDWARE_ERROR exception on the
#     load.  As the oldest instruction it takes the trap at commit: flush_ex.
#     The in-flight offload is squashed from the scoreboard, refetched and
#     issued *again* after the trap handler returns.
#  4. The handler only skips the faulting load (mepc += 4, mret), then the
#     offload and three independent `addi`s refill scoreboard slots 0..3.
#  5. The first execution's result returns late, tagged with the *old*
#     trans_id (1).  Slot 1 now holds `addi s1`, so the stale CVXIF result is
#     written into it and the `addi` retires with the wrong value.
#
# Markers:
#   0x8000_1000 = DONE   (0xdeadbeef when the program finished)
#   0x8000_1008 = R_A0   (a0 as committed)
#   0x8000_1010 = R_S3   (306 if correct)
#   0x8000_1018 = R_S2   (206 if correct)
#   0x8000_1020 = R_S1   (106 if correct; 1 if the stale result landed here)
# -----------------------------------------------------------------------------

  .section .text.main, "ax", @progbits
  .globl _start
_start:
  li    t0, 0x80001008
  sw    zero, 0(t0)               # R_A0 = 0
  li    t0, 0x80001010
  sw    zero, 0(t0)               # R_S3 = 0
  li    t0, 0x80001018
  sw    zero, 0(t0)               # R_S2 = 0
  li    t0, 0x80001020
  sw    zero, 0(t0)               # R_S1 = 0

  la    t0, trap_handler
  csrw  mtvec, t0                 # direct mode: HARDWARE_ERROR traps here

  li    t1, 6                     # rs1
  li    t2, 7                     # rs2
  li    t5, 0x40000000            # outside all region rules -> uncacheable read
  lw    t4, 0(t5)                 # testbench answers with SLVERR after +err_lat

  .word 0x0073050B                # custom0 a0, t1, t2   (opcode 0001011)

  # independent of a0, so they issue while the offload is still in flight
  addi  s1, t1, 100               # -> 106  (stale result target, old trans_id 1)
  addi  s2, t1, 200               # -> 206
  addi  s3, t1, 300               # -> 306

  li    t3, 0x80001008
  sw    a0, 0(t3)                 # R_A0
  li    t3, 0x80001010
  sw    s3, 0(t3)                 # R_S3
  li    t3, 0x80001018
  sw    s2, 0(t3)                 # R_S2
  li    t3, 0x80001020
  sw    s1, 0(t3)                 # R_S1 : 106 correct, 1 = stale CVXIF result
  li    t3, 0x80001000
  li    t4, 0xdeadbeef
  sw    t4, 0(t3)                 # DONE
.Lend:
  j     .Lend

  .balign 4
trap_handler:                     # HARDWARE_ERROR on the lw: skip it, continue
  csrr  t0, mepc
  addi  t0, t0, 4                 # t0/t4 only: t1/t2 must survive for custom0
  csrw  mepc, t0
  mret
