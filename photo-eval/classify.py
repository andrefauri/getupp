"""
Photo classification validation script.
Tests Claude's vision API on in-bed vs out-of-bed photos.

Usage:
    python classify.py --prompt prompts/v1.txt --model claude-haiku-4-5
    python classify.py --prompt prompts/v1.txt --model claude-sonnet-4-6
"""

import argparse
import base64
import csv
import io
import json
import os
import re
import time
from datetime import date
from pathlib import Path

import anthropic
from dotenv import load_dotenv
from PIL import Image, ImageOps
from typing import Optional

# USD per million tokens: {model: {input, output}}
PRICING = {
    "claude-haiku-4-5": {"input": 0.80, "output": 4.00},
    "claude-sonnet-4-6": {"input": 3.00, "output": 15.00},
}

PHOTO_FOLDERS = ["in-bed", "out-of-bed", "adversarial"]
PHOTO_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}


def load_and_resize_image(path: Path) -> str:
    """Open image, apply EXIF orientation, resize to max 1024px longest side, return base64 JPEG."""
    img = Image.open(path)
    img = ImageOps.exif_transpose(img)
    img = img.convert("RGB")
    max_side = 1024
    if max(img.size) > max_side:
        ratio = max_side / max(img.size)
        new_size = (int(img.width * ratio), int(img.height * ratio))
        img = img.resize(new_size, Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=80)
    return base64.standard_b64encode(buf.getvalue()).decode("utf-8")


def parse_model_response(text: str) -> Optional[dict]:
    """Parse JSON from model response, stripping markdown fences if present."""
    cleaned = text.strip()
    # Strip ```json ... ``` or ``` ... ``` fences
    cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
    cleaned = re.sub(r"\s*```$", "", cleaned)
    cleaned = cleaned.strip()
    try:
        data = json.loads(cleaned)
        if all(k in data for k in ("out_of_bed", "confidence", "reason")):
            return data
    except (json.JSONDecodeError, TypeError, ValueError):
        pass
    return None


def compute_cost(usage, model: str) -> float:
    """Compute cost in USD from API usage tokens."""
    pricing = PRICING.get(model)
    if not pricing:
        return 0.0
    input_cost = (usage.input_tokens / 1_000_000) * pricing["input"]
    output_cost = (usage.output_tokens / 1_000_000) * pricing["output"]
    return input_cost + output_cost


def ground_truth_for_folder(folder_name: str) -> bool:
    """Return expected out_of_bed value. adversarial is fail-closed (in-bed)."""
    return folder_name == "out-of-bed"


def main():
    load_dotenv()

    parser = argparse.ArgumentParser(description="Classify photos with Claude vision API")
    parser.add_argument("--prompt", required=True, help="Path to prompt text file")
    parser.add_argument("--model", default="claude-haiku-4-5", help="Claude model ID")
    parser.add_argument("--photos-dir", default="photos", help="Root photos directory")
    parser.add_argument("--results-dir", default="results", help="Output directory for CSVs")
    parser.add_argument("--limit", type=int, default=None, help="Process only the first N photos (for smoke testing)")
    args = parser.parse_args()

    prompt_path = Path(args.prompt)
    if not prompt_path.exists():
        raise SystemExit(f"Prompt file not found: {prompt_path}")

    prompt_text = prompt_path.read_text().strip()
    prompt_version = prompt_path.stem  # e.g. "v1" from "prompts/v1.txt"

    photos_root = Path(args.photos_dir)
    results_dir = Path(args.results_dir)
    os.makedirs(results_dir, exist_ok=True)

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise SystemExit("ANTHROPIC_API_KEY not set. Add it to .env or export it.")

    client = anthropic.Anthropic(api_key=api_key)

    # Collect all photos
    photos = []
    for folder in PHOTO_FOLDERS:
        folder_path = photos_root / folder
        if not folder_path.exists():
            print(f"Warning: folder not found, skipping: {folder_path}")
            continue
        for f in sorted(folder_path.iterdir()):
            if f.suffix.lower() in PHOTO_EXTENSIONS:
                photos.append((f, folder))

    if not photos:
        raise SystemExit(f"No photos found in {photos_root}/")

    if args.limit is not None:
        photos = photos[: args.limit]

    print(f"Model:   {args.model}")
    print(f"Prompt:  {prompt_path} ({prompt_version})")
    print(f"Photos:  {len(photos)}")
    print()

    rows = []
    for photo_path, folder in photos:
        ground_truth_bool = ground_truth_for_folder(folder)
        ground_truth_str = "out-of-bed" if ground_truth_bool else "in-bed"

        print(f"  {folder}/{photo_path.name} ... ", end="", flush=True)

        try:
            b64 = load_and_resize_image(photo_path)
        except Exception as e:
            print(f"IMAGE ERROR: {e}")
            rows.append({
                "photo": f"{folder}/{photo_path.name}",
                "ground_truth": ground_truth_str,
                "model_answer": "ERROR",
                "confidence": "",
                "correct": False,
                "reason": f"image_load_error: {e}",
                "latency_ms": "",
                "cost_usd": "",
            })
            continue

        t0 = time.monotonic()
        try:
            response = client.messages.create(
                model=args.model,
                max_tokens=256,
                messages=[{
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": b64,
                            },
                        },
                        {"type": "text", "text": prompt_text},
                    ],
                }],
            )
        except Exception as e:
            latency_ms = round((time.monotonic() - t0) * 1000)
            print(f"API ERROR: {e}")
            rows.append({
                "photo": f"{folder}/{photo_path.name}",
                "ground_truth": ground_truth_str,
                "model_answer": "ERROR",
                "confidence": "",
                "correct": False,
                "reason": f"api_error: {e}",
                "latency_ms": latency_ms,
                "cost_usd": "",
            })
            continue

        latency_ms = round((time.monotonic() - t0) * 1000)
        raw_text = response.content[0].text
        cost = compute_cost(response.usage, args.model)

        parsed = parse_model_response(raw_text)
        if parsed is None:
            print(f"PARSE ERROR (raw: {raw_text[:80]!r})")
            rows.append({
                "photo": f"{folder}/{photo_path.name}",
                "ground_truth": ground_truth_str,
                "model_answer": "ERROR",
                "confidence": "",
                "correct": False,
                "reason": f"parse_failure: {raw_text[:120]}",
                "latency_ms": latency_ms,
                "cost_usd": f"{cost:.6f}",
            })
            continue

        model_out_of_bed = bool(parsed["out_of_bed"])
        model_answer = "out-of-bed" if model_out_of_bed else "in-bed"
        correct = model_out_of_bed == ground_truth_bool
        confidence = float(parsed["confidence"])
        reason = str(parsed["reason"])

        status = "OK" if correct else "WRONG"
        print(f"{status}  answer={model_answer}  conf={confidence:.2f}  {latency_ms}ms  ${cost:.5f}")

        rows.append({
            "photo": f"{folder}/{photo_path.name}",
            "ground_truth": ground_truth_str,
            "model_answer": model_answer,
            "confidence": f"{confidence:.3f}",
            "correct": correct,
            "reason": reason,
            "latency_ms": latency_ms,
            "cost_usd": f"{cost:.6f}",
        })

    # Write CSV
    today = date.today().strftime("%Y-%m-%d")
    # Sanitize model name for filename
    model_slug = args.model.replace("/", "-")
    csv_name = f"{today}_{prompt_version}_{model_slug}.csv"
    csv_path = results_dir / csv_name
    fieldnames = ["photo", "ground_truth", "model_answer", "confidence", "correct", "reason", "latency_ms", "cost_usd"]
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nResults saved to: {csv_path}")

    # Summary
    valid_rows = [r for r in rows if r["model_answer"] != "ERROR"]
    error_rows = [r for r in rows if r["model_answer"] == "ERROR"]
    total = len(rows)
    correct_count = sum(1 for r in valid_rows if r["correct"] is True)
    accuracy = correct_count / total if total else 0.0

    latencies = [r["latency_ms"] for r in rows if r["latency_ms"] != ""]
    avg_latency = sum(latencies) / len(latencies) if latencies else 0

    costs = [float(r["cost_usd"]) for r in rows if r["cost_usd"] != ""]
    total_cost = sum(costs)

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"Total photos:    {total}")
    print(f"Errors:          {len(error_rows)}")
    print(f"Overall accuracy: {correct_count}/{total} = {accuracy:.1%}")
    print()

    # Per-folder accuracy
    for folder in PHOTO_FOLDERS:
        folder_rows = [r for r in rows if r["photo"].startswith(f"{folder}/")]
        if not folder_rows:
            continue
        folder_correct = sum(1 for r in folder_rows if r["correct"] is True)
        print(f"  {folder:<15} {folder_correct}/{len(folder_rows)} = {folder_correct/len(folder_rows):.1%}")

    print()
    print(f"Avg latency:     {avg_latency:.0f} ms")
    print(f"Total cost:      ${total_cost:.4f}")

    misclassified = [r for r in valid_rows if not r["correct"]]
    if misclassified:
        print(f"\nMisclassified ({len(misclassified)}):")
        for r in misclassified:
            print(f"  {r['photo']}")
            print(f"    expected={r['ground_truth']}  got={r['model_answer']}  conf={r['confidence']}")
            print(f"    reason: {r['reason']}")
    else:
        print("\nNo misclassifications!")

    if error_rows:
        print(f"\nErrors ({len(error_rows)}):")
        for r in error_rows:
            print(f"  {r['photo']}: {r['reason'][:100]}")


if __name__ == "__main__":
    main()
