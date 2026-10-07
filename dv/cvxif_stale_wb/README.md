# CVA6 CV-X-IF stale-writeback PoC

A CV-X-IF offload that is squashed by a pipeline flush is never cancelled: the
coprocessor is committed to it at issue time with `commit_kill = 1'b0`
(`cvxif_issue_register_commit_if_driver.sv:64`) and `cvxif_fu` has no flush
input, so its result comes back later tagged with the **old trans_id**.  By then
the scoreboard has been flushed and the id re-used, so the result is accepted
into whatever instruction now occupies that slot.

Two independent triggers are provided.  Both only need an instruction that is
**older than the offload but retires long after the offload has been issued**,
so that the flush lands while the offload is still in flight:

| PoC | flush source | how the window is opened |
|---|---|---|
| `prog_fence.S` | a `fence` that waits in commit until the store buffer drains | pure software, no TB help |
| `prog_buserr.S` | an older `lw` whose read is answered `SLVERR` (after a TB-chosen delay) on the core's top-level AXI port | fault injection through the memory bus; the response timing is the knob |

An external interrupt / debug request does **not** work as a trigger: they are
injected at decode onto a *younger* instruction (`decoder.sv:2011` attaches the
trap to whatever is in the ID stage), and in-order commit means the flush can
only land after the older offload has completed - or before it was ever issued.
A faulting instruction whose error arrives over the bus (like `prog_buserr.S`)
is the injection that does open the window, because the carrier is *older* and
the error response latency is externally controlled.

## Layout

| file | purpose |
|---|---|
| `tb_cva6_cvxif.sv` | top level: flat 64-bit AXI4 memory with read-error injection (`+err_addr`/`+err_lat`), the `cva6` core **DUT**, a multi-outstanding CV-X-IF coprocessor stub, an RVFI trace, and direct observation of the scoreboard write-back acceptance |
| `prog_fence.S` | directed testcase: pending store + `fence` + `custom0` + three independent `addi`s |
| `prog_buserr.S` | directed testcase: erroring `lw` (0x4000_0000) + `custom0` + three independent `addi`s, with a trap handler that skips the faulting load |
| `cva6_config_pkg.sv` | target config: cv32a60x-like, no MMU, `CvxifEn=1` |
| `link.ld`, `gen_hex.py` | program image helpers |
| `gen_filelist.py` | flattens `core/Flist.cva6` into `filelist.f` |
| `repro.sh` | build + run |

The coprocessor stub accepts every offload (multi-outstanding, like a pipelined
coprocessor), returns each result after 40 cycles tagged with the id it was
issued with, and returns a **unique execution counter** so the two executions of
the same instruction are distinguishable.  Nothing inside the core is forced.

## Build / run

```sh
./repro.sh            # build (if needed) and run both PoCs
./repro.sh fence      # only the fence PoC
./repro.sh buserr     # only the bus-error PoC (+err_addr=0x40000000 +err_lat=6)
./repro.sh -b         # only build
./repro.sh -w         # ... and dump FSDB into waves/
```

Requires VCS and `riscv64-unknown-elf-*`.

## Observed results

Both runs issue the same `custom0` twice and let the first execution's result
return after the flush, tagged with the pre-flush trans_id:

```
fence :
CVXIF ISSUE   cyc=101 id=2 instr=0073050b      <- first execution, trans_id 2
FLUSH_EX      cyc=103                          <- the fence retires and flushes
CVXIF ISSUE   cyc=109 id=0 instr=0073050b      <- same instruction re-issued (slot 0)
CVXIF RESULT  cyc=142 id=2 rd=x10 data=1 we=1  <- STALE result, old trans_id 2
WB ACCEPT     cyc=142 port=4 id=2 slot_fu=ALU slot_pc=80000040   <- addi s2!
CVXIF RESULT  cyc=150 id=0 rd=x10 data=2 we=1  <- real (second) result
DONE cycles=185 R_A0=00000002 R_S3=00000132 R_S2=00000001 R_S1=0000006a

buserr:
CVXIF ISSUE   cyc=111 id=3 instr=0073050b      <- first execution, trans_id 3
BUSERR RESP   cyc=120 addr=40000000 (held 6 cycles)
FLUSH_EX      cyc=123                          <- lw raises HARDWARE_ERROR at commit
FLUSH_EX      cyc=142                          <- (handler mret redirect)
CVXIF ISSUE   cyc=147 id=0 instr=0073050b      <- same instruction re-issued (slot 0)
CVXIF RESULT  cyc=152 id=3 rd=x10 data=1 we=1  <- STALE result, old trans_id 3
WB ACCEPT     cyc=152 port=4 id=3 slot_fu=ALU slot_pc=80000058   <- addi s3!
CVXIF RESULT  cyc=188 id=0 rd=x10 data=2 we=1  <- real (second) result
DONE cycles=218 R_A0=00000002 R_S3=00000001 R_S2=000000ce R_S1=0000006a
```

* The offload is issued **twice** - the core re-sends a non-cancellable offload,
  so the coprocessor executes the instruction twice (the stub returns 1 then 2).
* fence: the first execution's result (id 2) is accepted into the slot that now
  holds `addi s2, t1, 200` (pc=0x80000040); `R_S2 = 0x1` instead of `0xce`.
* buserr: the same race with the first execution tagged id 3; after the trap
  handler returns, slot 3 holds `addi s3, t1, 300` (pc=0x80000058), so
  `R_S3 = 0x1` instead of `0x132`.  The corruption is precisely the slot
  collision: `R_A0`/`R_S1`/`R_S2` are all correct.

The stale result is accepted because the only guard is
`scoreboard.sv:198 if (wt_valid_i[i] && mem_q[trans_id_i[i]].issued)`: after the
flush the slots are re-issued, and the scoreboard has no way to tell a
pre-flush write-back from a current one.  The flush also restarts allocation at
trans_id 0 (`scoreboard.sv:279`), which is what re-uses the old id.  In the
`err_lat=18` range the same stale result arrives while the scoreboard is
momentarily empty (post-`mret`) and is silently dropped by the `issued` guard -
the corruption needs the id to be live again, which `err_lat<=6` guarantees.

## Why the bus-error path is a legitimate trigger

The SLVERR is an architecturally visible event (a peripheral region answering
an error), not a TB shortcut: `hpdcache_mem_to_axi_read.sv:68` maps it to
`MEM_RESP_NOK`, `hpdcache_uncached.sv:440` flags the uncacheable read (the
address sits outside every region rule, `cva6_hpdcache_if_adapter.sv:81`), and
`load_unit.sv:497-509` turns it into a precise `HARDWARE_ERROR` exception on
the load.  The core takes the trap in order at commit and flushes - exactly the
`fence` timing, with the window width chosen by the TB (`+err_lat`).  An AMO
waiting on memory or an `sfence.vma` reaches the same state.

## Suggested fix

The trans_id is not unique across a flush, so a result cannot be attributed by
id alone.  Either carry a generation/epoch tag with the offload and drop results
from an older epoch, or implement real cancellation (`commit_kill`): the driver
currently hard-codes `commit_kill = 1'b0` and the core has no path to retract a
commit.  A bitmap of "in-flight offload ids marked at flush" only works if the
coprocessor returns results in order, because after the flush the same
instruction legitimately re-uses the same id.
