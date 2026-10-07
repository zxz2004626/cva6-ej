# -----------------------------------------------------------------------------
# prog_fence.S -- CVA6 CV-X-IF stale-result testcase (fence variant)
#
#  1. A store is issued so the `fence` below has something to wait for; the
#     fence then stalls in the commit stage until the store buffer drains.
#  2. `custom0 a0, t1, t2` is issued *while the fence is still committing*; it
#     is offloaded to the coprocessor and committed with `commit_kill = 0`, so
#     the coprocessor is never told to cancel it.
#  3. The fence finally retires and flushes the pipeline.  The offload is
#     squashed from the scoreboard, refetched and issued *again* into slot 0
#     with a new trans_id.
#  4. Three independent ALU instructions follow the offload and fill slots
#     1..3 of the 4-entry scoreboard before the offload completes.
#  5. The first execution's result returns late, tagged with the *old*
#     trans_id (2).  Slot 2 now holds `addi s2`, so the stale CVXIF result is
#     written into it and the `addi` retires with the wrong value.
#
# Markers:
#   0x8000_1000 = DONE   (0xdeadbeef when the program finished)
#   0x8000_1008 = R_A0   (a0 as committed)
#   0x8000_1010 = R_S3   (306 if correct)
#   0x8000_1018 = R_S2   (206 if correct; 1 if the stale result landed here)
# -----------------------------------------------------------------------------

  .section .text.main, "ax", @progbits
  .globl _start
_start:
  li    t0, 0x80001008
  sw    zero, 0(t0)               # R_A0 = 0
  li    t0, 0x80001010
  sw    zero, 0(t0)               # R_S3 = 0

  li    t1, 6                     # rs1
  li    t2, 7                     # rs2
  li    t5, 0x1234
  li    t6, 0x8000100c
  sw    t5, 0(t6)                 # pending store -> keeps the fence in commit
  fence
  .word 0x0073050B                # custom0 a0, t1, t2   (opcode 0001011)

  # independent of a0, so they issue while the offload is still in flight
  addi  s1, t1, 100               # slot 1 -> 106
  addi  s2, t1, 200               # slot 2 -> 206
  addi  s3, t1, 300               # slot 3 -> 306  (stale result target)

  li    t3, 0x80001008
  sw    a0, 0(t3)                 # R_A0
  li    t3, 0x80001010
  sw    s3, 0(t3)                 # R_S3
  li    t3, 0x80001018
  sw    s2, 0(t3)                 # R_S2 : 206 correct, 1 = stale CVXIF result
  li    t3, 0x80001020
  sw    s1, 0(t3)                 # R_S1 (sanity)
  li    t3, 0x80001000
  li    t4, 0xdeadbeef
  sw    t4, 0(t3)                 # DONE
.Lend:
  j     .Lend
