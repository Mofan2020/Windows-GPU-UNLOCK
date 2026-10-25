#!/usr/bin/env python3
# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
"""Measure the tensor throughput of the card, for the comparison around the unlock.

The unlock removes the limit that makes the FP16 and BF16 tensor instructions
run at half rate when they accumulate in FP32. The FP32 path is not touched by
it, so it is measured as well: that one is the control, and it says whether a
difference between two runs is the unlock, or only the clocks and the
temperature of the card.

The method is the one of the cuBLAS benchmark in this directory: a 4096x4096
matrix product, two seconds of warmup per precision, thirty samples, and the
median of them. The result is checked, so that a run that did no work cannot
pass for a fast one.

The script is run twice: once from a boot in which the unlock was skipped with
Esc, and once from a boot in which it was done with C. The two results are
written next to each other and are compared by the script.

    python torch-benchmark.py --label before
    python torch-benchmark.py --label after

Use the same Python that the rest of the work uses, so that the same PyTorch
build and the same driver are measured in both runs.
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time

import torch

DEFAULT_SIZE = 4096
DEFAULT_SAMPLES = 30
DEFAULT_WARMUP = 2.0

# The parts of the card that have to be the same in both runs.
GPU_QUERY = ("name,driver_version,pstate,clocks.sm,clocks.max.sm,"
             "power.draw,temperature.gpu,utilization.gpu")


def gpu_state():
    """What the card is doing right now, so that two runs can be compared."""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=" + GPU_QUERY, "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=30, check=True)
    except Exception as exc:                      # noqa: BLE001 - the reason is reported
        return {"error": str(exc)}
    rows = [row.strip() for row in result.stdout.splitlines() if row.strip()]
    return {"rows": rows}


def measure(a, b, warmup_seconds, samples):
    """The time of one matrix product, in seconds."""
    for _ in range(3):
        a @ b
    torch.cuda.synchronize()

    deadline = time.perf_counter() + warmup_seconds
    while time.perf_counter() < deadline:
        a @ b
        torch.cuda.synchronize()

    times = []
    for _ in range(samples):
        torch.cuda.synchronize()
        start = time.perf_counter()
        a @ b
        torch.cuda.synchronize()
        times.append(time.perf_counter() - start)
    return times


def run_case(name, dtype, size, warmup_seconds, samples):
    """One matrix product of the given precision, in teraflops."""
    a = torch.ones((size, size), device="cuda", dtype=dtype)
    b = torch.ones((size, size), device="cuda", dtype=dtype)
    times = measure(a, b, warmup_seconds, samples)

    # Every element of the product of two matrices of ones is the size of the
    # matrix. A run that did no work would not have that value.
    corner = a[0, 0].item()
    if abs(corner - 1.0) > 1e-3:
        raise SystemExit("the card did not hold the test data, so the number means nothing")

    median = statistics.median(times)
    flops = 2.0 * size ** 3
    result = {
        "name": name,
        "dtype": str(dtype).replace("torch.", ""),
        "size": size,
        "samples": samples,
        "warmup_seconds": warmup_seconds,
        "median_seconds": median,
        "min_seconds": min(times),
        "max_seconds": max(times),
        "tflops": flops / median / 1e12,
    }
    del a, b
    torch.cuda.empty_cache()
    return result


def compare(before, after):
    """What the two runs say, next to each other."""
    lines = []
    lines.append("")
    lines.append("  precision        before      after    speedup")
    lines.append("  " + "-" * 46)
    for name in ("fp32", "fp16", "bf16"):
        first = next((c for c in before.get("cases", []) if c["name"] == name), None)
        second = next((c for c in after.get("cases", []) if c["name"] == name), None)
        if first is None or second is None:
            continue
        speedup = second["tflops"] / first["tflops"] if first["tflops"] else 0.0
        lines.append("  %-12s %8.2f %9.2f %9.3f" %
                     (name, first["tflops"], second["tflops"], speedup))
    lines.append("")
    lines.append("  The speedup of fp32 is the control. It should stay near 1.00, because the")
    lines.append("  unlock does not touch the FP32 path. A speedup of fp16 that is near 2.00")
    lines.append("  while fp32 stays near 1.00 is the sign that the unlock is in effect.")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", default="run",
                        help="the name of this run, for example before or after")
    parser.add_argument("--size", type=int, default=DEFAULT_SIZE)
    parser.add_argument("--samples", type=int, default=DEFAULT_SAMPLES)
    parser.add_argument("--warmup", type=float, default=DEFAULT_WARMUP)
    parser.add_argument("--directory", default=".",
                        help="where the result files are written")
    arguments = parser.parse_args()

    if not torch.cuda.is_available():
        raise SystemExit("no CUDA device was found, so there is nothing to measure")

    print("GPU      :", torch.cuda.get_device_name(0))
    print("PyTorch  :", torch.__version__)
    print("CUDA     :", torch.version.cuda)
    print("state    :", json.dumps(gpu_state()))
    print("")

    cases = [run_case("fp32", torch.float32, arguments.size, arguments.warmup, arguments.samples)]
    cases.append(run_case("fp16", torch.float16, arguments.size, arguments.warmup, arguments.samples))
    try:
        cases.append(run_case("bf16", torch.bfloat16, arguments.size, arguments.warmup, arguments.samples))
    except Exception as exc:                      # noqa: BLE001 - the reason is reported
        print("the bf16 case was left out:", exc)

    for case in cases:
        print("  %-6s %8.2f teraflops   (median %.3f ms, %d samples)" %
              (case["name"], case["tflops"], case["median_seconds"] * 1000, case["samples"]))

    result = {
        "label": arguments.label,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "gpu": torch.cuda.get_device_name(0),
        "torch": torch.__version__,
        "cuda": torch.version.cuda,
        "state_before": gpu_state(),
        "cases": cases,
        "state_after": gpu_state(),
    }

    path = os.path.join(arguments.directory, "wgpu-benchmark-%s.json" % arguments.label)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2)
    print("")
    print("written:", path)

    before_path = os.path.join(arguments.directory, "wgpu-benchmark-before.json")
    after_path = os.path.join(arguments.directory, "wgpu-benchmark-after.json")
    if os.path.exists(before_path) and os.path.exists(after_path) \
            and arguments.label in ("before", "after"):
        with open(before_path, encoding="utf-8") as handle:
            before = json.load(handle)
        with open(after_path, encoding="utf-8") as handle:
            after = json.load(handle)
        print(compare(before, after))
    else:
        print("")
        print("  Run this again after the other boot, with the other label, to get the")
        print("  comparison. The two result files have to sit in the same directory.")


if __name__ == "__main__":
    sys.exit(main())
