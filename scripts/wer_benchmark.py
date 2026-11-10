#!/usr/bin/env python3
"""Calculate corpus WER and error counts from a JSONL reference/hypothesis set."""

from __future__ import annotations

import argparse
import json
import re
import unicodedata
from pathlib import Path


def tokens(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).lower().replace("ё", "е")
    return re.findall(r"[\w]+(?:[-'][\w]+)*", normalized, flags=re.UNICODE)


def align(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int]:
    # Each cell is (edit distance, substitutions, deletions, insertions).
    dp = [[(0, 0, 0, 0) for _ in range(len(hypothesis) + 1)] for _ in range(len(reference) + 1)]
    for i in range(1, len(reference) + 1):
        dp[i][0] = (i, 0, i, 0)
    for j in range(1, len(hypothesis) + 1):
        dp[0][j] = (j, 0, 0, j)
    for i, ref in enumerate(reference, 1):
        for j, hyp in enumerate(hypothesis, 1):
            prev = dp[i - 1][j - 1]
            sub_cost = int(ref != hyp)
            choices = [
                (prev[0] + sub_cost, prev[1] + sub_cost, prev[2], prev[3]),
                (dp[i - 1][j][0] + 1, dp[i - 1][j][1], dp[i - 1][j][2] + 1, dp[i - 1][j][3]),
                (dp[i][j - 1][0] + 1, dp[i][j - 1][1], dp[i][j - 1][2], dp[i][j - 1][3] + 1),
            ]
            dp[i][j] = min(choices, key=lambda value: value[0])
    _, substitutions, deletions, insertions = dp[-1][-1]
    return substitutions, deletions, insertions


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path, help="JSONL with id, reference, hypothesis")
    args = parser.parse_args()
    samples = [json.loads(line) for line in args.dataset.read_text().splitlines() if line.strip()]
    substitutions = deletions = insertions = reference_words = 0
    for row in samples:
        ref, hyp = tokens(row["reference"]), tokens(row["hypothesis"])
        s, d, i = align(ref, hyp)
        substitutions += s
        deletions += d
        insertions += i
        reference_words += len(ref)
    wer = (substitutions + deletions + insertions) / reference_words if reference_words else 0.0
    print(json.dumps({"samples": len(samples), "reference_words": reference_words, "substitutions": substitutions, "deletions": deletions, "insertions": insertions, "wer": round(wer, 5)}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
