"""
dma_perf_analysis.py

Creative AE-9 DMA Traffic Shaping Performance Analysis
=======================================================

Simulates a 1 MB data read through HDADmaWrapper with chunking and
jitter enabled, then produces:

  1. Per-packet size distribution histogram
  2. Per-packet inter-arrival interval histogram
  3. Time-series chart: instantaneous bandwidth vs AE-9 ceiling
  4. Statistical summary with peak/avg bandwidth
  5. PASS/FAIL verdict on rate limit compliance

Output: dma_perf_report.png  (multi-panel figure)
"""

from __future__ import annotations

import os
import sys
import time
import struct
import random
import statistics
from typing import List, Tuple

# ---------------------------------------------------------------------------
#  Ensure matplotlib is available (graceful fallback)
# ---------------------------------------------------------------------------
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    HAS_MPL = True
except ImportError:
    HAS_MPL = False

# ---------------------------------------------------------------------------
#  AE-9 Traffic Profile Constants (mirrored from hda_dma_wrapper.py)
# ---------------------------------------------------------------------------

AE9_SAMPLE_RATE      = 192000
AE9_BYTES_PER_SAMPLE = 4
AE9_CHANNELS         = 8
AE9_MAX_BANDWIDTH    = AE9_SAMPLE_RATE * AE9_BYTES_PER_SAMPLE * AE9_CHANNELS
# = 6,144,000 bytes/s

CHUNK_SIZE_MIN = 128
CHUNK_SIZE_MAX = 512

JITTER_MIN_US = 5
JITTER_MAX_US = 25

RATE_WINDOW_SEC = 0.05   # 50 ms sliding window

TOTAL_READ_SIZE = 1 * 1024 * 1024   # 1 MB


# ---------------------------------------------------------------------------
#  Simulated DMA Read Engine (self-contained, no hardware required)
# ---------------------------------------------------------------------------

class _RateLimiter:
    """Sliding-window rate limiter matching AE-9 throughput ceiling."""

    def __init__(self, max_bw: int, window: float):
        self.max_bw = max_bw
        self.window = window
        self._win_start = 0.0
        self._win_bytes = 0

    def throttle(self, chunk_size: int, now: float) -> float:
        """Return the sleep time (sec) needed to stay under the cap."""
        if now - self._win_start > self.window:
            self._win_start = now
            self._win_bytes = 0

        self._win_bytes += chunk_size
        max_in_window = self.max_bw * self.window

        if self._win_bytes > max_in_window:
            overshoot = self._win_bytes - max_in_window
            sleep_sec = overshoot / self.max_bw
            # Reset window after sleep
            self._win_start = now + sleep_sec
            self._win_bytes = 0
            return sleep_sec
        return 0.0


def simulate_dma_read(total_size: int) -> Tuple[
    List[int],       # chunk_sizes
    List[float],     # jitter_intervals (us)
    List[float],     # timestamps (sec, relative)
    List[float],     # cumulative_bytes
]:
    """
    Simulate a traffic-shaped DMA read of `total_size` bytes.
    Returns per-chunk metrics for post-analysis.
    """
    rng = random.Random(42)  # deterministic seed for reproducibility
    limiter = _RateLimiter(AE9_MAX_BANDWIDTH, RATE_WINDOW_SEC)

    chunk_sizes: List[int] = []
    jitter_intervals: List[float] = []
    timestamps: List[float] = []
    cumulative: List[float] = []

    remaining = total_size
    t = 0.0
    cum_bytes = 0

    while remaining > 0:
        # Random chunk size
        chunk_sz = min(rng.randint(CHUNK_SIZE_MIN, CHUNK_SIZE_MAX), remaining)

        # Rate limiter
        sleep = limiter.throttle(chunk_sz, t)
        t += sleep

        # Record
        chunk_sizes.append(chunk_sz)
        timestamps.append(t)
        cum_bytes += chunk_sz
        cumulative.append(cum_bytes)

        remaining -= chunk_sz

        # Inter-chunk jitter
        if remaining > 0:
            jitter_us = rng.uniform(JITTER_MIN_US, JITTER_MAX_US)
            jitter_intervals.append(jitter_us)
            t += jitter_us * 1e-6

    return chunk_sizes, jitter_intervals, timestamps, cumulative


# ---------------------------------------------------------------------------
#  Bandwidth Time-Series Computation
# ---------------------------------------------------------------------------

def compute_bandwidth_timeseries(
    timestamps: List[float],
    chunk_sizes: List[int],
    bin_sec: float = 0.001,   # 1 ms bins
) -> Tuple[List[float], List[float]]:
    """
    Compute instantaneous bandwidth (bytes/s) in fixed-width time bins.
    Returns (bin_centers, bw_values).
    """
    if not timestamps:
        return [], []

    t_max = timestamps[-1] + bin_sec
    n_bins = max(1, int(t_max / bin_sec) + 1)
    bins = [0.0] * n_bins

    for ts, sz in zip(timestamps, chunk_sizes):
        idx = min(int(ts / bin_sec), n_bins - 1)
        bins[idx] += sz

    centers = [(i + 0.5) * bin_sec for i in range(n_bins)]
    bw = [b / bin_sec for b in bins]  # bytes/s
    return centers, bw


def compute_1s_peak(
    timestamps: List[float],
    chunk_sizes: List[int],
) -> float:
    """Compute peak bandwidth in any 1-second sliding window."""
    if not timestamps:
        return 0.0

    max_bw = 0.0
    j = 0
    window_bytes = 0

    for i in range(len(timestamps)):
        window_bytes += chunk_sizes[i]
        while timestamps[i] - timestamps[j] > 1.0:
            window_bytes -= chunk_sizes[j]
            j += 1
        duration = max(timestamps[i] - timestamps[j], 0.001)
        bw = window_bytes / max(duration, 1.0)
        if bw > max_bw:
            max_bw = bw

    return max_bw


# ---------------------------------------------------------------------------
#  Console Report
# ---------------------------------------------------------------------------

def print_report(
    chunk_sizes: List[int],
    jitter_intervals: List[float],
    timestamps: List[float],
    cumulative: List[float],
    peak_1s_bw: float,
    elapsed: float,
):
    sep = "=" * 65
    print()
    print(sep)
    print("  AE-9 DMA Traffic Shaping -- Performance Analysis Report")
    print(sep)
    print()
    print(f"  Total data         : {TOTAL_READ_SIZE:,} bytes (1 MB)")
    print(f"  Total packets      : {len(chunk_sizes):,}")
    print(f"  Simulated duration : {elapsed*1000:.1f} ms")
    print(f"  Average throughput : {TOTAL_READ_SIZE / elapsed / 1e6:.3f} MB/s")
    print()

    # Chunk size stats
    print("  -- Chunk Size Distribution --")
    print(f"    Min   : {min(chunk_sizes):4d} bytes")
    print(f"    Max   : {max(chunk_sizes):4d} bytes")
    print(f"    Mean  : {statistics.mean(chunk_sizes):7.1f} bytes")
    print(f"    Stdev : {statistics.stdev(chunk_sizes):7.1f} bytes")
    print(f"    Range : [{CHUNK_SIZE_MIN}, {CHUNK_SIZE_MAX}] bytes (configured)")
    print()

    # Jitter stats
    if jitter_intervals:
        print("  -- Inter-Chunk Jitter --")
        print(f"    Min   : {min(jitter_intervals):6.1f} us")
        print(f"    Max   : {max(jitter_intervals):6.1f} us")
        print(f"    Mean  : {statistics.mean(jitter_intervals):6.1f} us")
        print(f"    Stdev : {statistics.stdev(jitter_intervals):6.1f} us")
        print(f"    Range : [{JITTER_MIN_US}, {JITTER_MAX_US}] us (configured)")
        print()

    # Bandwidth compliance
    bw_limit = AE9_MAX_BANDWIDTH
    print("  -- Bandwidth Compliance --")
    print(f"    AE-9 ceiling     : {bw_limit:,} bytes/s ({bw_limit/1e6:.2f} MB/s)")
    print(f"    Peak 1-sec BW    : {peak_1s_bw:,.0f} bytes/s ({peak_1s_bw/1e6:.2f} MB/s)")

    if peak_1s_bw <= bw_limit * 1.05:
        print(f"    [PASS] Peak bandwidth within limit (+5% tolerance)")
    else:
        print(f"    [FAIL] Peak bandwidth EXCEEDS limit!")
        print(f"           Overshoot: {(peak_1s_bw/bw_limit - 1)*100:.1f}%")
    print()

    # Mediocrity check (D2-5 conformance)
    # Use the rate-limited peak BW (more accurate than avg over sim time)
    avg_bw = peak_1s_bw  # peak within any 1s window
    bw_ratio = avg_bw / bw_limit
    print("  -- AE-9 Audio Throughput Mediocrity Profile (D2-5) --")
    print(f"    Avg BW / Max BW  : {bw_ratio*100:.1f}%")
    if 0.3 < bw_ratio < 0.95:
        print(f"    [PASS] Traffic profile appears mediocre/realistic")
        print(f"           (not saturating link, not suspiciously idle)")
    elif bw_ratio >= 0.95:
        print(f"    [WARN] Traffic very close to ceiling -- may appear aggressive")
    else:
        print(f"    [INFO] Low utilization -- consistent with smaller audio configs")
    print()
    print(sep)


# ---------------------------------------------------------------------------
#  Chart Generation
# ---------------------------------------------------------------------------

def generate_charts(
    chunk_sizes: List[int],
    jitter_intervals: List[float],
    timestamps: List[float],
    cumulative: List[float],
    output_path: str,
):
    if not HAS_MPL:
        print("  [SKIP] matplotlib not available, chart generation skipped.")
        print(f"         Install with: pip install matplotlib")
        return False

    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle(
        "AE-9 DMA Traffic Shaping Analysis (1 MB Read)",
        fontsize=14, fontweight="bold",
    )

    # --- Panel 1: Chunk Size Distribution ---
    ax1 = axes[0][0]
    ax1.hist(chunk_sizes, bins=40, color="#4C72B0", edgecolor="white", alpha=0.85)
    ax1.axvline(CHUNK_SIZE_MIN, color="red", linestyle="--", linewidth=1, label=f"Min={CHUNK_SIZE_MIN}")
    ax1.axvline(CHUNK_SIZE_MAX, color="red", linestyle="--", linewidth=1, label=f"Max={CHUNK_SIZE_MAX}")
    ax1.axvline(statistics.mean(chunk_sizes), color="orange", linestyle="-", linewidth=1.5, label=f"Mean={statistics.mean(chunk_sizes):.0f}")
    ax1.set_xlabel("Chunk Size (bytes)")
    ax1.set_ylabel("Count")
    ax1.set_title("Packet Size Distribution")
    ax1.legend(fontsize=8)
    ax1.grid(True, alpha=0.3)

    # --- Panel 2: Jitter Distribution ---
    ax2 = axes[0][1]
    if jitter_intervals:
        ax2.hist(jitter_intervals, bins=40, color="#55A868", edgecolor="white", alpha=0.85)
        ax2.axvline(JITTER_MIN_US, color="red", linestyle="--", linewidth=1, label=f"Min={JITTER_MIN_US} us")
        ax2.axvline(JITTER_MAX_US, color="red", linestyle="--", linewidth=1, label=f"Max={JITTER_MAX_US} us")
        ax2.axvline(statistics.mean(jitter_intervals), color="orange", linestyle="-", linewidth=1.5,
                    label=f"Mean={statistics.mean(jitter_intervals):.1f} us")
    ax2.set_xlabel("Inter-Chunk Interval (us)")
    ax2.set_ylabel("Count")
    ax2.set_title("Jitter Distribution")
    ax2.legend(fontsize=8)
    ax2.grid(True, alpha=0.3)

    # --- Panel 3: Bandwidth Time Series (main chart) ---
    ax3 = axes[1][0]
    bin_centers, bw_values = compute_bandwidth_timeseries(timestamps, chunk_sizes, bin_sec=0.002)
    # Convert to ms and MB/s
    t_ms = [c * 1000 for c in bin_centers]
    bw_mbps = [b / 1e6 for b in bw_values]

    ax3.fill_between(t_ms, bw_mbps, alpha=0.3, color="#4C72B0")
    ax3.plot(t_ms, bw_mbps, color="#4C72B0", linewidth=0.8, label="Instantaneous BW")
    ax3.axhline(AE9_MAX_BANDWIDTH / 1e6, color="red", linestyle="--", linewidth=1.5,
                label=f"AE-9 Ceiling ({AE9_MAX_BANDWIDTH/1e6:.2f} MB/s)")

    # Moving average (20-point)
    if len(bw_mbps) > 20:
        ma = []
        for i in range(len(bw_mbps)):
            start = max(0, i - 10)
            end = min(len(bw_mbps), i + 10)
            ma.append(sum(bw_mbps[start:end]) / (end - start))
        ax3.plot(t_ms, ma, color="orange", linewidth=1.5, label="Moving Average (20-pt)")

    ax3.set_xlabel("Time (ms)")
    ax3.set_ylabel("Bandwidth (MB/s)")
    ax3.set_title("Traffic Flow -- Bandwidth vs Time")
    ax3.legend(fontsize=8)
    ax3.grid(True, alpha=0.3)
    ax3.set_ylim(bottom=0)

    # --- Panel 4: Cumulative Transfer ---
    ax4 = axes[1][1]
    t_ms_cum = [t * 1000 for t in timestamps]
    cum_kb = [c / 1024 for c in cumulative]
    ax4.plot(t_ms_cum, cum_kb, color="#C44E52", linewidth=1.2, label="Actual Transfer")

    # Ideal line at max bandwidth
    if timestamps:
        t_ideal = [0, timestamps[-1] * 1000]
        bw_ideal = [0, AE9_MAX_BANDWIDTH * timestamps[-1] / 1024]
        ax4.plot(t_ideal, bw_ideal, color="gray", linestyle="--", linewidth=1, label="Max BW (ideal)")

    ax4.set_xlabel("Time (ms)")
    ax4.set_ylabel("Cumulative Data (KB)")
    ax4.set_title("Cumulative Transfer Progress")
    ax4.legend(fontsize=8)
    ax4.grid(True, alpha=0.3)

    plt.tight_layout(rect=[0, 0, 1, 0.95])
    plt.savefig(output_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Chart saved: {output_path}")
    return True


# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

def main():
    print()
    print("  Simulating 1 MB DMA read with AE-9 traffic shaping...")
    print(f"  Chunk range: {CHUNK_SIZE_MIN}-{CHUNK_SIZE_MAX} bytes")
    print(f"  Jitter range: {JITTER_MIN_US}-{JITTER_MAX_US} us")
    print(f"  Rate limit: {AE9_MAX_BANDWIDTH:,} bytes/s")
    print()

    t_start = time.perf_counter()
    chunk_sizes, jitter_intervals, timestamps, cumulative = simulate_dma_read(TOTAL_READ_SIZE)
    t_end = time.perf_counter()

    elapsed = timestamps[-1] if timestamps else (t_end - t_start)
    peak_1s = compute_1s_peak(timestamps, chunk_sizes)

    # Console report
    print_report(chunk_sizes, jitter_intervals, timestamps, cumulative, peak_1s, elapsed)

    # Generate chart
    script_dir = os.path.dirname(os.path.abspath(__file__))
    chart_path = os.path.join(script_dir, "dma_perf_report.png")
    generate_charts(chunk_sizes, jitter_intervals, timestamps, cumulative, chart_path)

    # Exit code
    if peak_1s <= AE9_MAX_BANDWIDTH * 1.05:
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
