#!/usr/bin/env python3
"""Cluster-aware descriptive and exploratory significance summary for audit JSON."""

from __future__ import annotations

import argparse
import json
import random
import statistics
from collections import defaultdict
from pathlib import Path


def interval(values: list[float], seed: int = 20261109) -> list[float] | None:
    if not values:
        return None
    rng = random.Random(seed)
    samples = sorted(statistics.mean(rng.choice(values) for _ in values) for _ in range(20000))
    return [samples[int(0.025 * len(samples))], samples[int(0.975 * len(samples))]]


def sign_test(values: list[float]) -> dict:
    nonzero = [x for x in values if x != 0]
    positive = sum(x > 0 for x in nonzero)
    n = len(nonzero)
    # One-sided exact binomial test against p=0.5.
    p = sum(__import__("math").comb(n, k) for k in range(positive, n + 1)) / (2**n) if n else 1.0
    return {"positive": positive, "nonzero": n, "one_sided_p": p}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit_json", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    data = json.loads(args.audit_json.read_text())
    rows = [r for r in data.get("boundaries", []) if r.get("statistically_usable")]
    speech_rows = [r for r in rows if r.get("speech_usable", True)]
    by_recording: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        by_recording[row["recording_id"]].append(row)

    cluster_mean_dist = [statistics.mean(r["split_continuous_distance"] for r in group) for group in by_recording.values()]
    threshold_rates = {}
    speech_threshold_rates = {}
    for threshold in (0.10, 0.20, 0.30, 0.50):
        cluster_rates = [statistics.mean(r["split_continuous_distance"] > threshold for r in group) for group in by_recording.values()]
        speech_cluster_rates = [statistics.mean(r["split_continuous_distance"] > threshold for r in group if r.get("speech_usable", True)) for group in by_recording.values() if any(r.get("speech_usable", True) for r in group)]
        speech_threshold_rates[str(threshold)] = {
            "boundaries_over_threshold": sum(r["split_continuous_distance"] > threshold for r in speech_rows),
            "boundary_rate": sum(r["split_continuous_distance"] > threshold for r in speech_rows) / len(speech_rows) if speech_rows else None,
            "recording_cluster_bootstrap_95pct_CI": interval(speech_cluster_rates),
        }
        threshold_rates[str(threshold)] = {
            "boundaries_over_threshold": sum(r["split_continuous_distance"] > threshold for r in rows),
            "boundary_rate": sum(r["split_continuous_distance"] > threshold for r in rows) / len(rows) if rows else None,
            "recording_cluster_bootstrap_95pct_CI": interval(cluster_rates),
        }

    controls = [r for r in rows if r.get("has_repeat_control")]
    paired_by_recording: dict[str, list[float]] = defaultdict(list)
    for row in controls:
        paired_by_recording[row["recording_id"]].append(row["split_continuous_distance"] - row["split_repeat_distance"])
    paired_clusters = [statistics.mean(v) for v in paired_by_recording.values()]
    summary = {
        "source_protocol": data.get("protocol"),
        "audio_uploaded": data.get("audio_uploaded", False),
        "eligible_recordings": data.get("recordings_considered"),
        "analyzed_boundaries": len(rows),
        "speech_usable_boundaries": len(speech_rows),
        "speech_usable_recording_clusters": len({r["recording_id"] for r in speech_rows}),
        "unique_recording_clusters": len(by_recording),
        "mean_split_vs_continuous_normalized_word_distance": statistics.mean(r["split_continuous_distance"] for r in rows) if rows else None,
        "recording_cluster_bootstrap_95pct_CI_mean_distance": interval(cluster_mean_dist),
        "disagreement_thresholds": threshold_rates,
        "speech_usable_sensitivity": {
            "mean_split_vs_continuous_distance": statistics.mean(r["split_continuous_distance"] for r in speech_rows) if speech_rows else None,
            "disagreement_thresholds": speech_threshold_rates,
        },
        "repeat_control_boundaries": len(controls),
        "repeat_control_recording_clusters": len(paired_clusters),
        "mean_excess_distance_vs_repeat": statistics.mean(paired_clusters) if paired_clusters else None,
        "recording_cluster_bootstrap_95pct_CI_excess_distance": interval(paired_clusters),
        "paired_cluster_sign_test": sign_test(paired_clusters),
        "caveat": "Exploratory context-sensitivity analysis only. ASR output is not ground truth; normalized edit distance and thresholds are not WER or confirmed boundary-induced error rates. The sign test is low-powered when repeat controls are sparse.",
    }
    output = json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(output)
    print(output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
