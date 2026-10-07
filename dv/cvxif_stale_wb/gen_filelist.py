#!/usr/bin/env python3
"""Flatten core/Flist.cva6 into a self-contained filelist for the zcmt PoC.

* substitutes ${CVA6_REPO_DIR} / ${HPDCACHE_DIR}
* replaces the target config package with this directory's cva6_config_pkg.sv
* inlines any `-F <flist>` reference (recursively)
"""
import os, sys

ROOT = os.environ.get("CVA6_REPO_DIR", "/home/zxz/cva6")
HPD  = os.environ.get("HPDCACHE_DIR", os.path.join(ROOT, "core/cache_subsystem/hpdcache"))
HERE = os.path.dirname(os.path.abspath(__file__))
SUB  = {"${CVA6_REPO_DIR}": ROOT, "${HPDCACHE_DIR}": HPD}

def subst(s):
    for k, v in SUB.items():
        s = s.replace(k, v)
    return s

def expand(path, out, seen):
    ap = os.path.abspath(path)
    if ap in seen: return
    seen.add(ap)
    for raw in open(ap):
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        line = line.replace("${CVA6_REPO_DIR}/core/include/${TARGET_CFG}_config_pkg.sv",
                            os.path.join(HERE, "cva6_config_pkg.sv"))
        line = subst(line)
        if line.startswith("-F ") or line.startswith("-f "):
            ref = line[3:].strip()
            if not os.path.isabs(ref):
                ref = os.path.join(os.path.dirname(ap), ref)
            expand(ref, out, seen)
        else:
            out.append(line)

out, seen = [], set()
expand(os.path.join(ROOT, "core/Flist.cva6"), out, seen)
open(os.path.join(HERE, "filelist.f"), "w").write("\n".join(out) + "\n")
print("wrote filelist.f: %d entries" % len(out))
