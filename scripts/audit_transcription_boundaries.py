#!/usr/bin/env python3
"""Audit historical 25-second GigaAM chunk boundaries against whole-window ASR.

Reads only the local Golosok history/audio archive and bundled transcribe-cli.
Outputs anonymized recording IDs, timing, text hypotheses and a JSON report locally.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
import time
import wave
import random
import statistics
import math
from pathlib import Path


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as audio:
        return audio.getnframes() / audio.getframerate()


def run_asr(cli: Path, model: Path, audio: Path) -> tuple[str, float]:
    started = time.perf_counter()
    result = subprocess.run(
        [str(cli), "-q", "-m", str(model), "--timestamps", "word", str(audio)],
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed = time.perf_counter() - started
    if result.returncode:
        raise RuntimeError(f"ASR failed for {audio.name}: {result.stderr[-1000:]}")
    match = re.search(r"^text:\s*(.*)$", result.stdout, flags=re.MULTILINE)
    return (match.group(1).strip() if match else ""), elapsed


def word_tokens(text: str) -> list[str]:
    return re.findall(r"[\w]+(?:[-'][\w]+)*", text.lower(), flags=re.UNICODE)


def similarity(left: str, right: str) -> float:
    a, b = word_tokens(left), word_tokens(right)
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(cur[-1] + 1, prev[j] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return 1 - prev[-1] / max(len(a), len(b))


def normalized_distance(left: str, right: str) -> float:
    a, b = word_tokens(left.replace("(empty)", "")), word_tokens(right.replace("(empty)", ""))
    if not a and not b:
        return 0.0
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(cur[-1] + 1, prev[j] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1] / max(len(a), len(b), 1)


def summarize(records: list[dict]) -> dict:
    usable = [r for r in records if r.get("statistically_usable") and r.get("has_repeat_control")]
    by_recording: dict[str, list[float]] = {}
    for row in usable:
        delta = row["split_continuous_distance"] - row["split_repeat_distance"]
        by_recording.setdefault(row["recording_id"], []).append(delta)
    clusters = [statistics.mean(values) for values in by_recording.values()]
    if not clusters:
        return {"usable_boundaries": 0, "repeat_control_boundaries": 0}
    rng = random.Random(20261109)
    boot = []
    for _ in range(10000):
        sample = [rng.choice(clusters) for _ in clusters]
        boot.append(statistics.mean(sample))
    boot.sort()
    positive = sum(d > 0 for d in clusters)
    nonzero = sum(d != 0 for d in clusters)
    # Exact one-sided sign test: split-vs-continuous worse than repeated-split variability.
    p_value = (sum(math.comb(nonzero, k) for k in range(positive, nonzero + 1)) / (2 ** nonzero)) if nonzero else 1.0
    return {
        "usable_boundaries": len(usable),
        "repeat_control_boundaries": len(usable),
        "recording_clusters": len(clusters),
        "mean_split_continuous_distance": round(statistics.mean(r["split_continuous_distance"] for r in usable), 4),
        "mean_split_repeat_distance": round(statistics.mean(r["split_repeat_distance"] for r in usable), 4),
        "mean_paired_excess_distance": round(statistics.mean(clusters), 4),
        "bootstrap_95pct_CI_excess_distance": [round(boot[int(0.025 * len(boot))], 4), round(boot[int(0.975 * len(boot))], 4)],
        "sign_test_positive_of_nonzero": [positive, nonzero],
        "sign_test_one_sided_p": round(p_value, 6),
        "interpretation": "Exploratory split-vs-whole disagreement relative to repeat variability, not WER and not ground-truth error prevalence.",
    }


def extract_window(source: Path, destination: Path, start: float, end: float) -> None:
    with wave.open(str(source), "rb") as src:
        params = src.getparams()
        rate = src.getframerate()
        first = max(0, int(start * rate))
        last = min(src.getnframes(), int(end * rate))
        if last <= first:
            raise ValueError(f"Empty audio interval [{start:.3f}, {end:.3f}] in {source.name}")
        src.setpos(first)
        frames = src.readframes(max(0, last - first))
    with wave.open(str(destination), "wb") as dst:
        dst.setparams(params)
        dst.writeframes(frames)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", type=Path, default=Path.home() / "Library/Application Support/Golosok/history.json")
    parser.add_argument("--audio-dir", type=Path, default=Path.home() / "Library/Application Support/Golosok/Audio")
    parser.add_argument("--cli", type=Path, default=Path("/Applications/Golosok.app/Contents/Resources/transcribe-cli"))
    parser.add_argument("--model", type=Path, default=Path("/Applications/Golosok.app/Contents/Resources/gigaam.gguf"))
    parser.add_argument("--window", type=float, default=4.0, help="seconds of context on each side of the old boundary")
    parser.add_argument("--repeats", type=int, default=2, help="number of repeats per split half for ASR variance")
    parser.add_argument("--resume", action="store_true", help="resume from existing partial JSON report")
    parser.add_argument("--repeat-every", type=int, default=1, help="run repeat controls every Nth eligible boundary; 0 disables repeat controls")
    parser.add_argument("--limit", type=int, default=0, help="maximum number of recordings; 0 means all eligible")
    parser.add_argument("--output", type=Path, default=Path("boundary-audit.json"))
    args = parser.parse_args()
    for path in (args.history, args.cli, args.model):
        if not path.exists():
            parser.error(f"Required local file not found: {path}")

    history = json.loads(args.history.read_text())
    eligible_by_path = {}
    skipped_short = 0
    for item in history:
        recording_id = item.get("id", "")
        audio = args.audio_dir / f"{recording_id}.wav"
        if audio.exists() and wav_duration(audio) > 25:
            eligible_by_path[audio] = (item, audio)
    eligible = list(eligible_by_path.values())
    if args.limit:
        eligible = eligible[:args.limit]

    report = {
        "protocol": "At each old 25s boundary: compare fresh GigaAM on full left and right windows with one continuous contextual window; repeat each half to estimate ASR variability; separately transcribe 2s core halves as diagnostics. ASR hypotheses are not ground truth.",
        "audio_uploaded": False,
        "recordings_considered": len(eligible),
        "boundaries": [],
    }
    started = time.perf_counter()
    eligible_boundary_index = 0
    completed_keys = set()
    if args.resume and args.output.exists():
        try:
            prior = json.loads(args.output.read_text())
            report["boundaries"] = prior.get("boundaries", [])
            completed_keys = {(r["recording_id"], r["boundary_sec"]) for r in report["boundaries"]}
        except (ValueError, OSError, KeyError):
            pass
    for item, audio in eligible:
        duration = wav_duration(audio)
        timing_path = args.audio_dir / f"{item['id']}.segments.json"
        saved_words = []
        if timing_path.exists():
            try:
                saved_words = json.loads(timing_path.read_text()).get("words", [])
            except (ValueError, OSError):
                pass
        boundary = 25.0
        while boundary + 2.0 <= duration:
            if (item["id"], boundary) in completed_keys:
                boundary += 25.0
                continue
            lo, hi = max(0, boundary - args.window), min(duration, boundary + args.window)
            eligible_boundary_index += 1
            do_repeat = args.repeat_every > 0 and (eligible_boundary_index - 1) % args.repeat_every == 0
            core_lo, core_hi = max(0, boundary - 2.0), min(duration, boundary + 2.0)
            with tempfile.TemporaryDirectory(prefix="golosok-boundary-") as temp:
                temp = Path(temp)
                whole, whole_time = temp / "continuous.wav", 0.0
                left, right = temp / "left.wav", temp / "right.wav"
                left_core, right_core = temp / "left-core.wav", temp / "right-core.wav"
                extract_window(audio, whole, lo, hi)
                extract_window(audio, left, lo, boundary)
                extract_window(audio, right, boundary, hi)
                if core_lo < boundary:
                    extract_window(audio, left_core, core_lo, boundary)
                else:
                    extract_window(audio, left_core, lo, boundary)
                if boundary < core_hi:
                    extract_window(audio, right_core, boundary, core_hi)
                else:
                    extract_window(audio, right_core, boundary, hi)
                continuous_text, whole_time = run_asr(args.cli, args.model, whole)
                left_text, left_time = run_asr(args.cli, args.model, left)
                right_text, right_time = run_asr(args.cli, args.model, right)
                repeat_pairs = []
                if do_repeat:
                    repeat_pairs = [
                        (run_asr(args.cli, args.model, left), run_asr(args.cli, args.model, right))
                        for _ in range(max(1, args.repeats - 1))
                    ]
                    repeat_left_text, repeat_left_time = repeat_pairs[-1][0]
                    repeat_right_text, repeat_right_time = repeat_pairs[-1][1]
                else:
                    repeat_left_text, repeat_right_text = left_text, right_text
                    repeat_left_time = repeat_right_time = 0.0
                left_core_text, left_core_time = run_asr(args.cli, args.model, left_core)
                right_core_text, right_core_time = run_asr(args.cli, args.model, right_core)
            original_left = " ".join(w.get("text", "") for w in saved_words if boundary - args.window <= w.get("start", -999) < boundary)
            original_right = " ".join(w.get("text", "") for w in saved_words if boundary <= w.get("start", -999) < boundary + args.window)
            original_core_left = " ".join(w.get("text", "") for w in saved_words if core_lo <= w.get("start", -999) < boundary)
            original_core_right = " ".join(w.get("text", "") for w in saved_words if boundary <= w.get("start", -999) < core_hi)
            old_combined = (original_core_left + " " + original_core_right).strip()
            independent = (left_text + " " + right_text).strip()
            repeated = (repeat_left_text + " " + repeat_right_text).strip()
            core_split = (left_core_text + " " + right_core_text).strip()
            report["boundaries"].append({
                "recording_id": item["id"], "duration_sec": round(duration, 2), "boundary_sec": boundary,
                "window_sec": [round(lo, 2), round(hi, 2)],
                "boundary_core_sec": [round(core_lo, 2), round(core_hi, 2)],
                "saved_original_left": original_left, "saved_original_right": original_right,
                "saved_original_boundary_core": old_combined,
                "fresh_split_left": left_text, "fresh_split_right": right_text,
                "fresh_continuous_window": continuous_text,
                "fresh_boundary_core_split_left": left_core_text, "fresh_boundary_core_split_right": right_core_text,
                "fresh_split_repeat_left": repeat_left_text, "fresh_split_repeat_right": repeat_right_text,
                "original_vs_continuous_similarity": round(similarity(old_combined, continuous_text.replace("(empty)", "")), 3),
                "split_vs_continuous_similarity": round(similarity(independent, continuous_text), 3),
                "fresh_split_repeat_similarity": round(similarity(independent, repeated), 3),
                "boundary_core_split_vs_continuous_similarity": round(similarity(core_split, continuous_text.replace("(empty)", "")), 3),
                "seconds_asr_original_window": round(whole_time, 3),
                "seconds_asr_two_split_windows": round(left_time + right_time, 3),
                "seconds_asr_repeat_control": round(sum(pair[0][1] + pair[1][1] for pair in repeat_pairs), 3),
                "seconds_asr_boundary_core_control": round(left_core_time + right_core_time, 3),
                "saved_timestamps_available": bool(saved_words),
                "statistically_usable": (boundary - lo >= 1.5 and hi - boundary >= 1.5),
                "has_repeat_control": do_repeat,
                "split_continuous_distance": round(normalized_distance(independent, continuous_text), 4),
                "split_repeat_distance": round(normalized_distance(independent, repeated), 4) if do_repeat else None,
                "left_window_duration_sec": round(boundary - lo, 3),
                "right_window_duration_sec": round(hi - boundary, 3),
                "left_word_count": len(word_tokens(left_text.replace("(empty)", ""))),
                "right_word_count": len(word_tokens(right_text.replace("(empty)", ""))),
                "whole_word_count": len(word_tokens(continuous_text.replace("(empty)", ""))),
                "speech_usable": (
                    len(word_tokens(left_text.replace("(empty)", ""))) >= 2
                    and len(word_tokens(right_text.replace("(empty)", ""))) >= 2
                    and len(word_tokens(continuous_text.replace("(empty)", ""))) >= 4
                ),
            })
            boundary += 25.0
            # Checkpoint so long runs can be resumed after cancellation or interruption.
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, ensure_ascii=False) + "\n")
        if boundary < duration:
            skipped_short += 1
    report["boundaries_skipped_insufficient_right_context"] = skipped_short
    report["statistical_summary"] = summarize(report["boundaries"])
    report["elapsed_sec"] = round(time.perf_counter() - started, 2)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Wrote {len(report['boundaries'])} boundary comparisons to {args.output} in {report['elapsed_sec']}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
