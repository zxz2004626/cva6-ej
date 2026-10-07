# Bug Report: CV-X-IF offload squashed by a pipeline flush is never cancelled — stale write-back corrupts an unrelated instruction

**Component:** `core` — CV-X-IF interface, scoreboard, issue stage
**Config:** cv32a60x-class (`CvxifEn=1`, `NrScoreboardEntries=4`, `TRANS_ID_BITS=2`), reproduced with `MmuPresent=0`; the mechanism is not MMU- or config-specific
**Affected version:** verified at commit `81245a47fad8fe1a5d562d953ef2662e099def76` (2026-09-15)
**Severity:** high — silent architectural-state corruption (wrong instruction result committed); no exception, no detection

---

## Summary

An offloaded custom instruction that is squashed by a pipeline flush is never
cancelled on the coprocessor side: the coprocessor is committed to the
instruction at issue time with `commit_kill = 1'b0`
(`core/cvxif_issue_register_commit_if_driver.sv:64`), and `cvxif_fu` has no
flush input, so the coprocessor has no way to learn that the offload was
squashed. The first execution's result therefore returns later tagged with the
**pre-flush trans_id**. By then the scoreboard has been flushed, trans_id
allocation has restarted at 0 (`core/scoreboard.sv:279`, `if (flush_i)
issue_pointer_n = '0`), and the id has been re-issued to a *different*
instruction. The stale write-back is accepted into that slot and the unrelated
instruction retires with the coprocessor's value.

The only acceptance guard is
`core/scoreboard.sv:198`:

```systemverilog
if (wt_valid_i[i] && mem_q[trans_id_i[i]].issued) begin
```

`issued` cannot distinguish a pre-flush write-back from a current one, because
trans_ids are not unique across a flush.

## Reproduction

Self-contained PoC in `dv/cvxif_stale_wb/` (VCS + `riscv64-unknown-elf-*`):

```sh
cd dv/cvxif_stale_wb
./repro.sh            # runs both triggers
```

Nothing inside the core is forced. The coprocessor stub is well-behaved and
CV-X-IF compliant: it accepts every offload, returns each result after 40
cycles tagged with the id it was issued with, and returns a unique execution
counter so the two executions of the same instruction are distinguishable.

### Trigger condition

The flushing instruction must be **older than the offload and retire after the
offload has been issued** (i.e. its issue→commit latency must exceed the time
for the offload behind it to reach the issue stage). Two independent triggers
are demonstrated:

1. **`fence` (pure software).** A pending store keeps the `fence` in the commit
   stage until the store buffer drains; the `custom0` behind it is issued while
   the fence is still committing. When the fence retires it flushes the
   pipeline and squashes the in-flight offload.
2. **Load bus error (top-level fault injection).** An older `lw` targeting an
   address outside every memory-region rule travels to the AXI port as an
   uncacheable single-beat transaction; the testbench holds the response for a
   chosen number of cycles and then answers `rresp = SLVERR`. The SLVERR maps
   to `HPDCACHE_MEM_RESP_NOK` (`hpdcache_mem_to_axi_read.sv:68`), is flagged on
   the uncacheable read (`hpdcache_uncached.sv:440`), and becomes a precise
   `HARDWARE_ERROR` exception on the load (`core/load_unit.sv:497-509`), which
   takes the trap in order at commit — same timing as the `fence`, with the
   window width externally controllable.

An AMO waiting on memory, `sfence.vma`, `mret`/`ecall` with an older
long-latency instruction, or a CSR write with side effects reach the same
state. External interrupts and debug requests do **not**: they are injected at
decode onto a *younger* instruction (`core/decoder.sv:2011`), so in-order
commit guarantees the flush lands either after the offload has completed or
before it was ever issued.

### Observed behaviour (fence trigger)

```
CVXIF ISSUE   cyc=101 id=2 instr=0073050b      <- first execution, trans_id 2
FLUSH_EX      cyc=103                          <- the fence retires and flushes
CVXIF ISSUE   cyc=109 id=0 instr=0073050b      <- same instruction re-issued (slot 0)
CVXIF RESULT  cyc=142 id=2 rd=x10 data=1 we=1  <- STALE result, old trans_id 2
WB ACCEPT     cyc=142 port=4 id=2 slot_fu=ALU slot_pc=80000040   <- addi s2!
CVXIF RESULT  cyc=150 id=0 rd=x10 data=2 we=1  <- real (second) result
DONE cycles=185 R_A0=00000002 R_S3=00000132 R_S2=00000001 R_S1=0000006a
```

The pre-flush result (id 2) is accepted into the scoreboard slot that now
holds `addi s2, t1, 200` (pc = 0x8000_0040). That `addi` retires with the
coprocessor value:

* **expected:** `R_S2 = 0x0000_00ce` (206)
* **actual:** `R_S2 = 0x0000_0001` (the first execution's counter)

`R_A0 = 2` (the re-issued execution's result) and `R_S1`/`R_S3` are correct —
the corruption is precisely the trans_id collision.

### Observed behaviour (bus-error trigger, `+err_addr=0x40000000 +err_lat=6`)

```
CVXIF ISSUE   cyc=111 id=3 instr=0073050b      <- first execution, trans_id 3
BUSERR RESP   cyc=120 addr=40000000 (held 6 cycles)
FLUSH_EX      cyc=123                          <- lw raises HARDWARE_ERROR at commit
FLUSH_EX      cyc=142                          <- (trap-handler mret redirect)
CVXIF ISSUE   cyc=147 id=0 instr=0073050b      <- same instruction re-issued (slot 0)
CVXIF RESULT  cyc=152 id=3 rd=x10 data=1 we=1  <- STALE result, old trans_id 3
WB ACCEPT     cyc=152 port=4 id=3 slot_fu=ALU slot_pc=80000058   <- addi s3!
DONE cycles=218 R_A0=00000002 R_S3=00000001 R_S2=000000ce R_S1=0000006a
```

Identical failure with a different root event: `R_S3 = 1` instead of
`0x132` (306).

Additional observable defects in both runs:

* The offload is executed **twice** by the coprocessor (the core re-sends a
  non-cancellable offload after the flush). For an offload with side effects
  this is a second correctness violation independent of the stale write-back.
* If the stale result happens to arrive while the collided slot is momentarily
  not issued (e.g. right after a follow-on flush), it is silently dropped by
  the `issued` guard — the failure mode then depends on cycle-level timing.

## Impact

Any CV-X-IF coprocessor that takes more than a few cycles to return a result
(i.e. any realistic pipelined coprocessor) can corrupt an arbitrary younger
instruction's architectural result whenever an older long-latency instruction
flushes the pipeline between the offload's issue and its write-back. The
corrupted instruction retires normally — the error is silent and
architecturally committed.

## Suggested fix

trans_id is not unique across a flush, so a result cannot be attributed by id
alone. Options:

1. **Epoch/generation tag:** carry a flush-generation counter with each
   offload (in `x_issue_req` or alongside the trans_id) and have the core drop
   results whose generation is older than the current one. Requires a small
   protocol extension or an out-of-band tag.
2. **Real cancellation:** implement `commit_kill` — the driver currently
   hard-codes `commit_kill = 1'b0` and the core has no path to retract a
   commit. The CV-X-IF commit interface already defines the semantics.

A bitmap of "in-flight offload ids marked at flush" only works if the
coprocessor returns results **in order**, because after the flush the same
instruction legitimately re-uses the same id.

## Files

| path | purpose |
|---|---|
| `dv/cvxif_stale_wb/tb_cva6_cvxif.sv` | testbench: flat AXI4 memory with read-error injection, cva6 DUT, compliant multi-outstanding coprocessor stub, scoreboard write-back observation |
| `dv/cvxif_stale_wb/prog_fence.S` | fence trigger testcase |
| `dv/cvxif_stale_wb/prog_buserr.S` | bus-error trigger testcase (with trap handler) |
| `dv/cvxif_stale_wb/repro.sh` | build + run both triggers |
| `dv/cvxif_stale_wb/README.md` | detailed analysis |
