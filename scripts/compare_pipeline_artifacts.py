#!/usr/bin/env python3
"""Compare two pipeline artifact sets, field by field.

Written for the CPU-only build work (plans/cpu-only-build.md, Verification F).
Matching `18526 / 0` is an acceptance check, not proof that the meshing result
was preserved -- this compares the artifacts themselves.

What it checks
--------------
* Every HDF5 dataset in every stage file: name set, dtype kind, shape.
* Integer/connectivity datasets: exact equality, plus a *canonicalized* topology
  comparison (per-cell indices sorted, then cells sorted lexicographically) so a
  pure reordering is reported as "same topology, different ordering" instead of
  a spurious mismatch. Raw checksums are deliberately not used: HDF5 byte
  equality would fail on any ordering change even when the mesh is identical.
* Floating-point datasets: max absolute and relative error against a tolerance.
* HDF5 root attributes.
* result.mesh: vertex coordinates (tolerance) and hexahedron connectivity
  (canonicalized, exact). Read with a small built-in MEDIT parser rather than
  meshio -- meshio's medit reader requires the element count on the line after
  the section keyword, and hex writes `Vertices 16729` on a single line.
* result_metrics.yaml: total_hexes and inverted_count exactly; the scaled
  Jacobian and Jacobian min/max/mean/std within tolerance.

On mismatch it reports the first offending dataset, the flat index of the worst
element, and the max absolute/relative error -- enough to start debugging from.

Tolerances
----------
The pipeline is not bit-deterministic run to run, so a tolerance of zero is not
achievable. Run `baseline` twice, feed both runs to `--emit-tolerances`, and the
observed run-to-run spread becomes the recorded tolerance floor. Any field that
differs between two runs of the *same* build is nondeterministic and is compared
against that recorded tolerance rather than silently ignored.

Usage
-----
  # derive tolerances from two runs of the same build
  compare_pipeline_artifacts.py emit-tolerances RUN_A RUN_B -o tolerances.json

  # compare a candidate against the baseline
  compare_pipeline_artifacts.py compare BASELINE CANDIDATE [-t tolerances.json]

  # write the compact, committable manifest for a run
  compare_pipeline_artifacts.py manifest RUN -o baseline_manifest.json

RUN is a directory laid out as
  <run>/stage_0_deformation.hdf5
  <run>/stage_1_decomposition.hdf5
  <run>/stage_2_discretization.hdf5
  <run>/stage_3_hexahedralization.hdf5
  <run>/result.mesh
  <run>/result_metrics.yaml
(scripts/collect_pipeline_artifacts.sh assembles that from output/runs/<name>/).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import h5py
import numpy as np

STAGE_FILES = [
    "stage_0_deformation.hdf5",
    "stage_1_decomposition.hdf5",
    "stage_2_discretization.hdf5",
    "stage_3_hexahedralization.hdf5",
]

# Datasets that encode topology. Compared exactly AND canonicalized.
CONNECTIVITY_HINTS = ("tets", "quads", "hexes", "patches", "ordering", "locked")

# Fallback tolerances, used when no tolerances file is supplied. Deliberately
# tight: the intent is that measured run-to-run spread replaces these.
DEFAULT_ATOL = 0.0
DEFAULT_RTOL = 0.0

# Quality statistics gated in result_metrics.yaml.
METRIC_STATS = ["min", "max", "mean", "std"]
METRIC_BLOCKS = ["scaled_jacobian", "jacobian"]

# How much wider than the baseline-vs-baseline p99 a candidate may spread before
# it is called out. Not a hard failure: it is a distribution signal, and the
# hard gate stays the recorded atol/rtol.
DIST_FACTOR = 2.0


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.notes: list[str] = []

    def fail(self, msg: str) -> None:
        self.failures.append(msg)
        print(f"  FAIL {msg}")

    def note(self, msg: str) -> None:
        self.notes.append(msg)
        print(f"  note {msg}")

    def ok(self, msg: str) -> None:
        print(f"  ok   {msg}")


def canonical_cells(arr: np.ndarray, name: str):
    """Return an ordering-independent view of a connectivity array.

    Handles the two layouts this pipeline uses:
      * 2-D (k, N) or (N, k) index arrays  -> cells are the k-tuples
      * the flat `hexes` array             -> 9-value records, 8 indices + -1
    Returns None when the layout is not recognised, in which case the caller
    falls back to exact comparison only and says so.
    """
    a = np.asarray(arr)
    if a.ndim == 2:
        cells = a.T if a.shape[0] < a.shape[1] else a
        if cells.shape[1] < 2:
            return None
        return np.sort(np.sort(cells, axis=1), axis=0)
    if a.ndim == 1 and name.endswith("hexes") and a.size % 9 == 0:
        rec = a.reshape(-1, 9)
        # Validate the assumed layout instead of trusting it.
        if not np.all(rec[:, 8] == -1):
            return None
        cells = rec[:, :8]
        return np.sort(np.sort(cells, axis=1), axis=0)
    return None


def compare_arrays(name: str, a: np.ndarray, b: np.ndarray, atol: float,
                   rtol: float, rep: Report, known_nondet: bool = False,
                   base_p99: float | None = None) -> None:
    a = np.asarray(a)
    b = np.asarray(b)

    if a.shape != b.shape:
        rep.fail(f"{name}: shape {a.shape} vs {b.shape}")
        return
    if a.dtype.kind != b.dtype.kind:
        rep.fail(f"{name}: dtype kind {a.dtype.kind} vs {b.dtype.kind}")
        return

    is_int = a.dtype.kind in "iub"
    looks_topological = any(h in name for h in CONNECTIVITY_HINTS)

    if is_int:
        if np.array_equal(a, b):
            rep.ok(f"{name}: identical ({a.dtype}, {a.shape})")
            return
        # Not byte-identical; is it the same mesh in a different order?
        if looks_topological:
            ca, cb = canonical_cells(a, name), canonical_cells(b, name)
            if ca is not None and cb is not None and np.array_equal(ca, cb):
                rep.fail(f"{name}: SAME canonical topology but DIFFERENT ordering "
                         f"-- ordering is not contractual here, review before accepting")
                return
            if ca is None:
                rep.note(f"{name}: layout not canonicalisable, exact comparison only")
        diff = np.flatnonzero(np.ravel(a) != np.ravel(b))
        i = int(diff[0])
        detail = (f"{diff.size} differing integer elements; first at flat "
                  f"index {i} ({np.ravel(a)[i]} vs {np.ravel(b)[i]})")
        if known_nondet:
            # Differs between two runs of the SAME build, so it cannot
            # discriminate builds. Recorded explicitly in the tolerances file,
            # never silently skipped -- and topology fields are excluded from
            # that list when it is generated.
            rep.note(f"{name}: recorded as nondeterministic -- {detail}")
        else:
            rep.fail(f"{name}: {detail}")
        return

    # Floating point.
    af = np.ravel(a).astype(np.float64)
    bf = np.ravel(b).astype(np.float64)
    if af.size == 0:
        rep.ok(f"{name}: empty")
        return
    abs_err = np.abs(af - bf)
    denom = np.maximum(np.abs(af), np.abs(bf))
    with np.errstate(divide="ignore", invalid="ignore"):
        rel_err = np.where(denom > 0, abs_err / denom, 0.0)
    max_abs = float(abs_err.max())
    max_rel = float(rel_err.max())
    worst = int(abs_err.argmax())

    p99 = float(np.percentile(abs_err, 99))
    p50 = float(np.percentile(abs_err, 50))
    dist = f"max={max_abs:.3e} p99={p99:.3e} p50={p50:.3e}"

    if max_abs <= atol or max_rel <= rtol:
        rep.ok(f"{name}: within tolerance ({dist}, max_rel={max_rel:.3e})")
        # A candidate can sit under a max-derived ceiling while being far worse
        # across the bulk of the data. Surface that rather than hide it.
        if base_p99 is not None and base_p99 > 0 and p99 > base_p99 * DIST_FACTOR:
            rep.note(f"{name}: p99 {p99:.3e} is >{DIST_FACTOR:g}x the "
                     f"baseline-vs-baseline p99 {base_p99:.3e} -- wider spread "
                     f"than run-to-run noise, worth a look")
    else:
        rep.fail(f"{name}: {dist} max_rel={max_rel:.6e} "
                 f"exceeds atol={atol:.3e}/rtol={rtol:.3e}; worst at flat index "
                 f"{worst} ({af[worst]!r} vs {bf[worst]!r})")


def collect_datasets(path: Path) -> dict:
    out = {}
    with h5py.File(path, "r") as f:
        def visit(name, obj):
            if isinstance(obj, h5py.Dataset):
                out[name] = obj[()]
        f.visititems(visit)
        out["__attrs__"] = {k: v for k, v in f.attrs.items()}
    return out


def compare_stage(path_a: Path, path_b: Path, tol: dict, rep: Report,
                  nondet: set | None = None) -> None:
    nondet = nondet or set()
    da, db = collect_datasets(path_a), collect_datasets(path_b)
    attrs_a, attrs_b = da.pop("__attrs__"), db.pop("__attrs__")

    only_a, only_b = set(da) - set(db), set(db) - set(da)
    if only_a:
        rep.fail(f"{path_a.name}: datasets missing from candidate: {sorted(only_a)}")
    if only_b:
        rep.fail(f"{path_a.name}: unexpected extra datasets: {sorted(only_b)}")

    for name in sorted(set(da) & set(db)):
        key = f"{path_a.name}:{name}"
        t = tol.get(key, {})
        compare_arrays(key, da[name], db[name],
                       t.get("atol", DEFAULT_ATOL), t.get("rtol", DEFAULT_RTOL), rep,
                       known_nondet=key in nondet, base_p99=t.get("observed_p99"))

    for k in sorted(set(attrs_a) | set(attrs_b)):
        if k not in attrs_a or k not in attrs_b:
            rep.fail(f"{path_a.name}: attribute '{k}' present in only one run")
            continue
        key = f"{path_a.name}:@{k}"
        t = tol.get(key, {})
        compare_arrays(key, np.asarray(attrs_a[k]), np.asarray(attrs_b[k]),
                       t.get("atol", DEFAULT_ATOL), t.get("rtol", DEFAULT_RTOL), rep,
                       known_nondet=key in nondet, base_p99=t.get("observed_p99"))


MEDIT_SECTIONS = {
    "Vertices": 3, "Edges": 2, "Triangles": 3, "Quadrilaterals": 4,
    "Tetrahedra": 4, "Hexahedra": 8,
}


def read_result_mesh(path: Path):
    """Minimal MEDIT (.mesh) reader for this project's output.

    meshio is not used here: its medit reader requires the element count on the
    line *after* the section keyword, while hex writes `Vertices 16729` on one
    line, which makes meshio raise `invalid literal for int()` on the first
    vertex row. plans/cpu-only-build.md allows the repository's own MEDIT reader
    instead; this is that, in Python. Both dialects are accepted.

    Returns (points Nx3 float64, hexes Mx8 int64 zero-based) -- hexes is None if
    the file has no hexahedron block.
    """
    tokens = path.read_text().split("\n")
    i, points, hexes = 0, None, None
    while i < len(tokens):
        line = tokens[i].strip()
        i += 1
        if not line:
            continue
        head = line.split()
        kw = head[0]
        if kw == "End":
            break
        if kw not in MEDIT_SECTIONS:
            continue  # MeshVersionFormatted, Dimension, comments
        width = MEDIT_SECTIONS[kw]
        if len(head) > 1:
            count = int(head[1])
        else:
            count = int(tokens[i].strip())
            i += 1
        rows = np.fromstring(" ".join(tokens[i:i + count]), sep=" ")
        i += count
        # Each row is `width` values plus a trailing reference tag.
        per_row = rows.size // count if count else 0
        rows = rows.reshape(count, per_row)[:, :width]
        if kw == "Vertices":
            points = rows.astype(np.float64)
        elif kw == "Hexahedra":
            hexes = rows.astype(np.int64) - 1  # MEDIT indices are 1-based
    if points is None:
        raise ValueError(f"{path}: no Vertices section found")
    return points, hexes


def compare_result_mesh(a: Path, b: Path, tol: dict, rep: Report) -> None:
    pa, ha = read_result_mesh(a)
    pb, hb = read_result_mesh(b)
    if pa.shape != pb.shape:
        rep.fail(f"result.mesh: vertex count {pa.shape} vs {pb.shape}")
    if ha is None or hb is None:
        rep.fail("result.mesh: no hexahedron cell block")
        return
    if ha.shape != hb.shape:
        rep.fail(f"result.mesh: hex count {ha.shape} vs {hb.shape}")
        return

    ca = np.sort(np.sort(ha, axis=1), axis=0)
    cb = np.sort(np.sort(hb, axis=1), axis=0)
    if np.array_equal(ca, cb):
        rep.ok(f"result.mesh: canonical hex connectivity identical ({ha.shape[0]} hexes)")
        if not np.array_equal(ha, hb):
            rep.note("result.mesh: hex ordering differs but topology is identical")
    else:
        d = np.flatnonzero(np.ravel(ca) != np.ravel(cb))
        rep.fail(f"result.mesh: canonical hex connectivity differs at "
                 f"{d.size} positions, first flat index {int(d[0])}")

    if pa.shape == pb.shape:
        t = tol.get("result.mesh:points", {})
        compare_arrays("result.mesh:points", pa, pb,
                       t.get("atol", DEFAULT_ATOL), t.get("rtol", DEFAULT_RTOL), rep,
                       base_p99=t.get("observed_p99"))


def parse_metrics(path: Path) -> dict:
    """Minimal reader for the flat/one-level result_metrics.yaml this tool emits.

    Deliberately not pulling in PyYAML: the file is two scalars plus two nested
    blocks of numbers, and the comparator should not gain a dependency the
    runtime images do not already have.
    """
    out, block = {}, None
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indented = raw[:1].isspace()
        line = raw.strip()
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        k, v = k.strip(), v.strip()
        if not v:
            block = k
            out[k] = {}
            continue
        if indented and block:
            try:
                out[block][k] = float(v)
            except ValueError:
                out[block][k] = v
        else:
            block = None
            try:
                out[k] = float(v)
            except ValueError:
                out[k] = v
    return out


def compare_metrics(a: Path, b: Path, tol: dict, rep: Report) -> None:
    ma, mb = parse_metrics(a), parse_metrics(b)

    for k in ("total_hexes", "inverted_count"):
        va, vb = ma.get(k), mb.get(k)
        if va is None or vb is None:
            rep.fail(f"result_metrics.yaml: '{k}' missing")
        elif va != vb:
            rep.fail(f"result_metrics.yaml: {k} {va} vs {vb} (must match exactly)")
        else:
            rep.ok(f"result_metrics.yaml: {k} = {va:g}")
    if ma.get("inverted_count", 1) != 0:
        rep.fail(f"result_metrics.yaml: inverted_count is {ma.get('inverted_count')}, must be 0")

    for blk in METRIC_BLOCKS:
        if blk not in ma or blk not in mb:
            rep.note(f"result_metrics.yaml: no '{blk}' block, skipped")
            continue
        for stat in METRIC_STATS:
            if stat not in ma[blk] or stat not in mb[blk]:
                continue
            key = f"result_metrics.yaml:{blk}.{stat}"
            t = tol.get(key, {})
            compare_arrays(key, np.array([ma[blk][stat]]), np.array([mb[blk][stat]]),
                           t.get("atol", DEFAULT_ATOL), t.get("rtol", DEFAULT_RTOL), rep,
                           base_p99=t.get("observed_p99"))


def artifact_paths(run: Path) -> list[tuple[str, Path]]:
    items = [(n, run / n) for n in STAGE_FILES]
    items += [("result.mesh", run / "result.mesh"),
              ("result_metrics.yaml", run / "result_metrics.yaml")]
    return items


def cmd_compare(args) -> int:
    a, b = Path(args.baseline), Path(args.candidate)
    doc = json.loads(Path(args.tolerances).read_text()) if args.tolerances else {}
    tol = doc.get("tolerances", {})
    nondet = set(doc.get("nondeterministic_exact", {}))
    rep = Report()

    print(f"baseline : {a}")
    print(f"candidate: {b}")
    print(f"tolerances: {args.tolerances or '(none -- exact match required)'}\n")

    for name, pa in artifact_paths(a):
        pb = b / name
        if not pa.exists() or not pb.exists():
            missing = pa if not pa.exists() else pb
            rep.fail(f"{name}: missing artifact {missing}")
            continue
        print(f"[{name}]")
        if name.endswith(".hdf5"):
            compare_stage(pa, pb, tol, rep, nondet)
        elif name == "result.mesh":
            compare_result_mesh(pa, pb, tol, rep)
        else:
            compare_metrics(pa, pb, tol, rep)
        print()

    if rep.failures:
        print(f"FAIL: {len(rep.failures)} mismatch(es)")
        for f in rep.failures[:20]:
            print(f"  - {f}")
        return 1
    print(f"PASS: artifacts match ({len(rep.notes)} note(s))")
    return 0


def cmd_emit_tolerances(args) -> int:
    """Measure run-to-run spread between two runs of the SAME build.

    Every field that differs becomes a recorded tolerance rather than an
    ignored difference. Integer/topology fields are never given a tolerance --
    if those differ between two runs the pipeline is not reproducible and that
    must be fixed, not tolerated.
    """
    a, b = Path(args.run_a), Path(args.run_b)
    tol: dict[str, dict] = {}
    nondet_exact: dict[str, dict] = {}
    margin = args.margin

    for name in STAGE_FILES:
        pa, pb = a / name, b / name
        if not (pa.exists() and pb.exists()):
            continue
        da, db = collect_datasets(pa), collect_datasets(pb)
        aa, ab = da.pop("__attrs__"), db.pop("__attrs__")
        for ds in sorted(set(da) & set(db)):
            arr_a, arr_b = np.asarray(da[ds]), np.asarray(db[ds])
            if arr_a.shape != arr_b.shape:
                continue
            if arr_a.dtype.kind in "iub":
                # Integer fields that differ between two runs of the same build
                # are nondeterministic. Topology is deliberately NOT eligible:
                # if connectivity is unstable the pipeline is broken, and that
                # must be fixed rather than tolerated.
                key = f"{name}:{ds}"
                if np.array_equal(arr_a, arr_b):
                    continue
                if any(h in key for h in CONNECTIVITY_HINTS):
                    print(f"  WARNING: topology field {key} differs between two runs "
                          f"of the same build; NOT recording a tolerance for it")
                    continue
                nondet_exact[key] = {
                    "differing_elements": int(np.count_nonzero(np.ravel(arr_a) != np.ravel(arr_b))),
                    "size": int(arr_a.size),
                    "note": "integer/metadata field, unstable across runs of the same build",
                }
                continue
            _record(tol, f"{name}:{ds}", arr_a, arr_b, margin)
        for k in sorted(set(aa) & set(ab)):
            arr_a, arr_b = np.asarray(aa[k]), np.asarray(ab[k])
            if arr_a.dtype.kind in "iub":
                continue
            _record(tol, f"{name}:@{k}", arr_a, arr_b, margin)

    if (a / "result.mesh").exists() and (b / "result.mesh").exists():
        pa, _ = read_result_mesh(a / "result.mesh")
        pb, _ = read_result_mesh(b / "result.mesh")
        if pa.shape == pb.shape:
            _record(tol, "result.mesh:points", pa, pb, margin)

    if (a / "result_metrics.yaml").exists() and (b / "result_metrics.yaml").exists():
        ma, mb = parse_metrics(a / "result_metrics.yaml"), parse_metrics(b / "result_metrics.yaml")
        for blk in METRIC_BLOCKS:
            if blk in ma and blk in mb:
                for stat in METRIC_STATS:
                    if stat in ma[blk] and stat in mb[blk]:
                        _record(tol, f"result_metrics.yaml:{blk}.{stat}",
                                np.array([ma[blk][stat]]), np.array([mb[blk][stat]]), margin)

    doc = {
        "_comment": (
            "Tolerances measured from two runs of the SAME build; each value is "
            "the observed run-to-run spread multiplied by the margin below. A "
            "field listed here is nondeterministic in this pipeline. Fields not "
            "listed must match exactly."
        ),
        "margin": margin,
        "run_a": str(a),
        "run_b": str(b),
        "tolerances": tol,
        "nondeterministic_exact": nondet_exact,
    }
    Path(args.output).write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.output}: {len(tol)} float field(s) with tolerance, "
          f"{len(nondet_exact)} nondeterministic integer field(s)")
    for k, v in sorted(nondet_exact.items()):
        print(f"  [int] {k}: {v['differing_elements']}/{v['size']} elements differ")
    for k, v in sorted(tol.items())[:15]:
        print(f"  {k}: atol={v['atol']:.3e} rtol={v['rtol']:.3e}")
    return 0


def _record(tol: dict, key: str, a: np.ndarray, b: np.ndarray, margin: float) -> None:
    af, bf = np.ravel(a).astype(np.float64), np.ravel(b).astype(np.float64)
    if af.size == 0:
        return
    abs_err = np.abs(af - bf)
    denom = np.maximum(np.abs(af), np.abs(bf))
    with np.errstate(divide="ignore", invalid="ignore"):
        rel_err = np.where(denom > 0, abs_err / denom, 0.0)
    max_abs, max_rel = float(abs_err.max()), float(rel_err.max())
    if max_abs == 0.0:
        return
    # The max alone is a poor summary: for result.mesh:points it is set by ~9
    # outlier vertices out of 16729, so a max-derived tolerance is very loose.
    # Record percentiles as well so `compare` can report whether the candidate
    # is worse *in distribution*, not merely under a generous ceiling.
    tol[key] = {
        "atol": max_abs * margin, "rtol": max_rel * margin,
        "observed_atol": max_abs, "observed_rel": max_rel,
        "observed_p99": float(np.percentile(abs_err, 99)),
        "observed_p50": float(np.percentile(abs_err, 50)),
        "count": int(af.size),
    }


def cmd_manifest(args) -> int:
    """Compact, committable summary: hashes, shapes, counts, statistics.

    Large HDF5 artifacts are deliberately NOT committed -- keep them as CI
    artifacts or release fixtures.
    """
    run = Path(args.run)
    man: dict = {"run": str(run), "stages": {}}

    for name in STAGE_FILES:
        p = run / name
        if not p.exists():
            continue
        entry = {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
                 "bytes": p.stat().st_size, "datasets": {}}
        d = collect_datasets(p)
        d.pop("__attrs__", None)
        for ds in sorted(d):
            arr = np.asarray(d[ds])
            info = {"dtype": str(arr.dtype), "shape": list(arr.shape)}
            if arr.dtype.kind == "f" and arr.size:
                f = np.ravel(arr).astype(np.float64)
                info |= {"min": float(f.min()), "max": float(f.max()),
                         "mean": float(f.mean()), "std": float(f.std())}
            elif arr.size:
                info |= {"min": int(np.ravel(arr).min()), "max": int(np.ravel(arr).max())}
            entry["datasets"][ds] = info
        man["stages"][name] = entry

    rm = run / "result.mesh"
    if rm.exists():
        pts, hexes = read_result_mesh(rm)
        man["result_mesh"] = {
            "num_vertices": int(pts.shape[0]),
            "num_hexes": int(hexes.shape[0]) if hexes is not None else 0,
            "canonical_topology_sha256": hashlib.sha256(
                np.sort(np.sort(hexes, axis=1), axis=0).tobytes()).hexdigest()
            if hexes is not None else None,
        }

    mm = run / "result_metrics.yaml"
    if mm.exists():
        man["result_metrics"] = parse_metrics(mm)

    if args.tolerances:
        man["tolerances"] = json.loads(Path(args.tolerances).read_text())

    Path(args.output).write_text(json.dumps(man, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.output}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("compare", help="compare a candidate run against a baseline")
    c.add_argument("baseline"); c.add_argument("candidate")
    c.add_argument("-t", "--tolerances")
    c.set_defaults(func=cmd_compare)

    e = sub.add_parser("emit-tolerances", help="measure run-to-run spread of one build")
    e.add_argument("run_a"); e.add_argument("run_b")
    e.add_argument("-o", "--output", required=True)
    e.add_argument("--margin", type=float, default=4.0,
                   help="multiply observed spread by this (default 4)")
    e.set_defaults(func=cmd_emit_tolerances)

    m = sub.add_parser("manifest", help="write the compact baseline manifest")
    m.add_argument("run"); m.add_argument("-o", "--output", required=True)
    m.add_argument("-t", "--tolerances")
    m.set_defaults(func=cmd_manifest)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
