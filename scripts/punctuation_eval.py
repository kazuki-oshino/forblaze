"""合成文だけを使うLaya評価。実アプリの入力処理には接続しない。"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import itertools
import json
import math
import os
from pathlib import Path
import platform
import random
import resource
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
PUNCTUATION = {"comma": "、", "period": "。", "none": ""}
ORDERS = list(itertools.permutations(PUNCTUATION))
# 二つの質問形式を結果を見る前に固定し、同じ文で比較する。
PROMPTS = {
    "ja": {
        "instructions": "日本語の文章の【境界】に入れる句読点を選んでください。"
        "自然な書き言葉に整えます。挨拶と名乗りは読点でつなぎます。"
        "独立した文は句点で区切り、単語や述語の途中は区切りません。"
        "【境界】以外の文字は変更しません。",
        "criteria": {"comma": "読点「、」でつなぐ", "period": "句点「。」で文を区切る",
                     "none": "句読点を入れずそのままつなぐ"},
    },
    "en": {
        "instructions": "Choose the punctuation at 【境界】 in the Japanese text. "
        "Use natural written Japanese. Join a greeting and self-introduction with a comma. "
        "Separate independent sentences with a period. Never split a word or predicate. "
        "Do not change any other characters.",
        "criteria": {"comma": "Japanese comma 、", "period": "Japanese period 。",
                     "none": "No punctuation; join the text directly"},
    },
}
# 初回の記号選択で「none」への偏りが見られた後に追加した診断用の比較形式。
PROMPTS["candidate_ja"] = {
    "instructions": "候補のうち、日本語の文章として最も自然なものを選んでください。"
    "挨拶と名乗りは読点でつなぎ、独立した文は句点で区切ります。"
    "単語や述語の途中は区切りません。",
}
PROMPTS["candidate_en"] = {
    "instructions": "Which candidate is the most natural written Japanese? "
    "Join greetings and self-introductions with a comma. "
    "Separate independent sentences with a period. Do not split words or predicates.",
}


def grade_case(case, choice):
    allowed = case["allowed"]
    scored = bool(allowed)
    return {
        "acceptable": choice in allowed if scored else None,
        "preferred": choice == case["preferred"] if case["preferred"] is not None else None,
        "changed": choice != case["original"],
        "improved": scored and case["original"] not in allowed and choice in allowed,
        "harmed": scored and case["original"] in allowed and choice not in allowed,
    }


def decode_answer(result):
    try:
        answer = result["answers"]["punctuation"]
        choice, probabilities = answer["choice"], answer["probabilities"]
        valid = (not result["usage"]["truncated"] and choice in PUNCTUATION
                 and set(probabilities) == set(PUNCTUATION)
                 and all(math.isfinite(p) and 0 <= p <= 1 for p in probabilities.values())
                 and abs(sum(probabilities.values()) - 1) <= .001
                 and probabilities[choice] == max(probabilities.values()))
        if not valid:
            raise ValueError("回答の形式・確率または入力予算が不正")
        return choice
    except (KeyError, TypeError) as error:
        raise ValueError("回答の形式が不正") from error


def render(case, choice):
    return case["left"] + PUNCTUATION[choice] + case["right"]


def make_request(case, prompt, order):
    if set(order) != set(PUNCTUATION) or len(order) != 3:
        raise ValueError("選択肢は重複のない3種類")
    preset = PROMPTS[prompt]
    if prompt.startswith("candidate_"):
        # 完成文はモデルに生成させず、3通りをコードで組み立てる。
        return "句読点だけが異なる三つの候補文を比較してください。", {
            "punctuation": {"type": "choice", "instructions": preset["instructions"],
                            "criteria": {key: render(case, key) for key in order}}
        }
    # 元の句読点・期待結果・理由・カテゴリは入力せず、アンカーだけを見せる。
    return case["left"] + "【境界】" + case["right"], {
        "punctuation": {"type": "choice", "instructions": preset["instructions"],
                        "criteria": {key: preset["criteria"][key] for key in order}}
    }


def validate_cases(cases):
    ids = [case["id"] for case in cases]
    if not ids or len(set(ids)) != len(ids):
        raise ValueError("空または重複した評価ID")
    for case in cases:
        if (case["original"] not in PUNCTUATION
                or not set(case["allowed"]) <= set(PUNCTUATION)
                or (case["allowed"] and case["preferred"] not in case["allowed"])
                or (not case["allowed"] and case["preferred"] is not None)
                or case["split"] not in ("development", "evaluation")
                or "【境界】" in case["left"] + case["right"]):
            raise ValueError(f"不正な評価例: {case['id']}")


def percentile(values, proportion):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[max(0, math.ceil(proportion * len(ordered)) - 1)]


def summarize(cases, rows):
    by_id = {case["id"]: case for case in cases}
    grades = [grade_case(by_id[row["id"]], row["choice"]) for row in rows]
    scored = sum(grade["acceptable"] is not None for grade in grades)
    return {
        "count": len(rows), "scored": scored,
        "acceptable": sum(grade["acceptable"] is True for grade in grades),
        "preferred": sum(grade["preferred"] is True for grade in grades),
        **{key: sum(grade[key] for grade in grades) for key in ("changed", "improved", "harmed")},
        "choice_counts": dict(Counter(row["choice"] for row in rows)),
        "latency_ms_p50": percentile([row["elapsed_ms"] for row in rows], .5),
        "latency_ms_p95": percentile([row["elapsed_ms"] for row in rows], .95),
        "latency_ms_max": max((row["elapsed_ms"] for row in rows), default=None),
    }


def fingerprint(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_prepared(agent, state, questions):
    items, _ = agent.prepare(state, questions)
    for item in items:
        if item["state_stats"]["truncated"]:
            raise ValueError("推論前に入力予算超過を検出")
        if item["options"]["options_distinct"] != 3:
            raise ValueError("選択肢のトークン表現が衝突")
    # laya-mlx 0.4.0には選択肢あたり48 tokenの上限がある。
    # usage.truncatedはstateだけを対象とするため、候補文と質問も別途検査する。
    for question in questions.values():
        option_lengths = [len(agent.tok(f" {key}: {value}", add_special_tokens=False)["input_ids"])
                          for key, value in question["criteria"].items()]
        head_length = len(agent.tok("choice question: " + question["instructions"],
                                    add_special_tokens=False)["input_ids"])
        if max(option_lengths) > 48 or sum(n + 1 for n in option_lengths) + head_length > agent.cfg["head_max_len"]:
            raise ValueError("選択肢または質問がランタイム内で切り詰められる")
    return [len(item["ids"]) for item in items]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=Path.home() / "Models/laya-multilingual-mlx")
    parser.add_argument("--cases", type=Path, default=ROOT / "tools/laya-eval/cases.json")
    parser.add_argument("--output", type=Path, default=ROOT / "build/laya-eval/results.json")
    parser.add_argument("--prompts", nargs="+", choices=list(PROMPTS), default=["ja", "en"])
    parser.add_argument("--split", choices=["all", "development", "evaluation"], default="all")
    args = parser.parse_args()
    model = args.model.expanduser().resolve(strict=True)
    cases = json.loads(args.cases.read_text())["cases"]
    validate_cases(cases)
    if args.split != "all":
        cases = [case for case in cases if case["split"] == args.split]
    manifest = json.loads((model / "manifest.json").read_text())
    hashes = {}
    for name, expected in manifest["files"].items():
        path = (model / name).resolve(strict=True)
        if not path.is_relative_to(model):
            raise ValueError("モデル外を参照するmanifest")
        hashes[name] = fingerprint(path)
        if hashes[name] != expected["sha256"]:
            raise ValueError(f"モデルのハッシュ不一致: {name}")

    os.environ.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
                      TOKENIZERS_PARALLELISM="false")
    network_attempts = []

    def audit(event, arguments):
        if event in ("socket.connect", "socket.getaddrinfo", "socket.sendto"):
            network_attempts.append(event)
            raise RuntimeError("評価中のPythonネットワーク接続を禁止")

    sys.addaudithook(audit)
    started = time.perf_counter()
    import laya_mlx as laya
    import mlx.core as mx
    import_ms = (time.perf_counter() - started) * 1000
    started = time.perf_counter()
    agent = laya.load(model, dtype="float16", device="gpu", batch_size=1)
    mx.synchronize()
    load_ms = (time.perf_counter() - started) * 1000
    print(f"model loaded: {load_ms:.1f} ms", flush=True)

    # 文脈予算を先に検査し、切り詰めを含む判定を成績に混ぜない。
    for case, prompt, order in itertools.product(cases, args.prompts, ORDERS):
        check_prepared(agent, *make_request(case, prompt, order))

    def run(case, prompt, order_index, phase):
        state, questions = make_request(case, prompt, ORDERS[order_index])
        mx.synchronize()
        start = time.perf_counter()
        result = agent.predict(state, questions)
        mx.synchronize()
        elapsed_ms = (time.perf_counter() - start) * 1000
        choice = decode_answer(result)
        return {"id": case["id"], "prompt": prompt, "order_index": order_index,
                "order": list(ORDERS[order_index]), "phase": phase, "choice": choice,
                "elapsed_ms": elapsed_ms, "result": result}

    # 初回GPU推論と追加5回をウォームアップとして別記録する。
    primary_prompt = args.prompts[0]
    warmup = [run(cases[0], primary_prompt, 0, "warmup") for _ in range(6)]
    rows = []
    jobs = list(itertools.product(cases, args.prompts, range(len(ORDERS))))
    random.Random(20261011).shuffle(jobs)
    for case, prompt, order_index in jobs:
        rows.append(run(case, prompt, order_index, "main"))
        if len(rows) % 50 == 0:
            print(f"evaluated {len(rows)}/{len(jobs)}", flush=True)
    # 同一入力で2回追加し、元の1回と合わせて再現性と暖機後の速度を測る。
    repeats = [run(case, primary_prompt, 0, "repeat") for _ in range(2) for case in cases]
    summaries = {}
    for prompt in args.prompts:
        canonical = [row for row in rows if row["prompt"] == prompt and row["order_index"] == 0]
        prompt_rows = [row for row in rows if row["prompt"] == prompt]
        flips = [case["id"] for case in cases
                 if len({row["choice"] for row in prompt_rows if row["id"] == case["id"]}) > 1]
        summaries[prompt] = {
            "canonical": summarize(cases, canonical),
            "evaluation_only": summarize(cases, [r for r in canonical
                if next(c for c in cases if c["id"] == r["id"])["split"] == "evaluation"]),
            "all_orders": summarize(cases, prompt_rows), "order_sensitive_ids": flips,
        }
    repeat_flips = [case["id"] for case in cases if len({row["choice"] for row in rows + repeats
        if row["id"] == case["id"] and row["prompt"] == primary_prompt and row["order_index"] == 0}) > 1]
    payload = {
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "environment": {"macos": platform.mac_ver()[0], "machine": platform.machine(),
            "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
            "memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
            "python": platform.python_version(),
            "packages": {name: importlib.metadata.version(name) for name in
                         ("laya-mlx", "mlx", "mlx-metal", "tokenizers", "numpy", "huggingface-hub")}},
        "model": {"repository": manifest["repository"], "source_revision": manifest["source_revision"],
                  "hashes": hashes, "dtype": "float16", "device": "gpu", "batch_size": 1,
                  "compile": False, "cache_prompts": False, "pad_to_multiple": None},
        "cases_sha256": fingerprint(args.cases), "script_sha256": fingerprint(Path(__file__)),
        "prompts": {key: PROMPTS[key] for key in args.prompts}, "split": args.split, "seed": 20261011,
        "import_ms": import_ms, "load_ms": load_ms, "warmup": warmup,
        "rss_peak_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "mlx_peak_bytes": mx.get_peak_memory(), "mlx_active_bytes": mx.get_active_memory(),
        "mlx_cache_bytes": mx.get_cache_memory(), "network_attempts_blocked": network_attempts,
        "offline_mode": "HF_HUB_OFFLINE=1; Python audit hook blocks socket connect/DNS/sendto",
        "summaries": summaries, "repeat_summary": summarize(cases, repeats),
        "repeat_choice_changed_ids": repeat_flips, "rows": rows, "repeats": repeats,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"summaries": summaries, "repeat_summary": payload["repeat_summary"],
                      "repeat_choice_changed_ids": repeat_flips}, ensure_ascii=False, indent=2))
    print(f"saved: {args.output}", flush=True)


if __name__ == "__main__":
    main()
