import copy
import json
from pathlib import Path
import unittest

from punctuation_eval import (check_prepared, decode_answer, grade_case, make_request,
                              percentile, render, summarize, validate_cases)


class PunctuationEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.case = {"left": "こんにちは", "right": "高須クリニックです。",
                     "original": "period", "allowed": ["comma", "period"],
                     "preferred": "comma"}
        self.result = {"answers": {"punctuation": {
            "choice": "comma", "probabilities": {"comma": .8, "period": .1, "none": .1}}},
            "usage": {"truncated": False}}

    def test_preference_is_not_a_grammatical_error(self):
        grade = grade_case(self.case, "period")
        self.assertTrue(grade["acceptable"])
        self.assertFalse(grade["preferred"])
        self.assertFalse(grade["harmed"])

    def test_harmful_change_is_counted(self):
        grade = grade_case(self.case, "none")
        self.assertFalse(grade["acceptable"])
        self.assertTrue(grade["changed"])
        self.assertTrue(grade["harmed"])

    def test_fixing_incorrect_original_is_an_improvement(self):
        self.case.update(original="period", allowed=["none"], preferred="none")
        grade = grade_case(self.case, "none")
        self.assertTrue(grade["improved"])
        self.assertFalse(grade["harmed"])

    def test_insufficient_context_is_not_scored_as_correct(self):
        self.case.update(allowed=[], preferred=None)
        grade = grade_case(self.case, "comma")
        self.assertIsNone(grade["acceptable"])
        self.assertIsNone(grade["preferred"])
        self.assertFalse(grade["harmed"])

    def test_render_changes_only_target_boundary(self):
        self.assertEqual(render(self.case, "comma"), "こんにちは、高須クリニックです。")
        self.assertEqual(render(self.case, "none"), "こんにちは高須クリニックです。")

    def test_unknown_choice_is_rejected(self):
        self.result["answers"]["punctuation"]["choice"] = "rewrite"
        with self.assertRaises(ValueError):
            decode_answer(self.result)

    def test_truncated_context_is_rejected(self):
        self.result["usage"]["truncated"] = True
        with self.assertRaises(ValueError):
            decode_answer(self.result)

    def test_malformed_probabilities_are_rejected(self):
        for probabilities in ({"comma": 1}, {"comma": float("nan"), "period": .1, "none": .1},
                              {"comma": -.1, "period": .5, "none": .6},
                              {"comma": .2, "period": .2, "none": .2}):
            result = copy.deepcopy(self.result)
            result["answers"]["punctuation"]["probabilities"] = probabilities
            with self.subTest(probabilities=probabilities), self.assertRaises(ValueError):
                decode_answer(result)

    def test_valid_result_decodes_semantic_label(self):
        self.assertEqual(decode_answer(self.result), "comma")

    def test_expected_labels_and_original_do_not_leak_into_prompt(self):
        changed_gold = {**self.case, "original": "none", "preferred": "period",
                        "allowed": ["none"], "reason": "secret rationale"}
        order = ("comma", "period", "none")
        self.assertEqual(make_request(self.case, "ja", order),
                         make_request(changed_gold, "ja", order))

    def test_reordering_preserves_label_meanings(self):
        state_a, a = make_request(self.case, "ja", ("comma", "period", "none"))
        state_b, b = make_request(self.case, "ja", ("none", "period", "comma"))
        self.assertEqual(state_a, state_b)
        self.assertEqual(a, b)
        self.assertEqual(list(b["punctuation"]["criteria"]), ["none", "period", "comma"])

    def test_unscored_cases_do_not_inflate_accuracy(self):
        a = {**self.case, "id": "a"}
        b = {**self.case, "id": "b", "allowed": [], "preferred": None}
        result = summarize([a, b], [
            {"id": "a", "choice": "comma", "elapsed_ms": 10},
            {"id": "b", "choice": "comma", "elapsed_ms": 20}])
        self.assertEqual(result["count"], 2)
        self.assertEqual(result["scored"], 1)
        self.assertEqual(result["acceptable"], 1)
        self.assertEqual(result["improved"], 0)
        self.assertEqual(percentile([], .95), None)
        self.assertEqual(result["latency_ms_p95"], 20)

    def test_preflight_rejects_truncation_before_inference(self):
        class FakeAgent:
            def prepare(self, state, questions):
                return [{"state_stats": {"truncated": True}}], []
        with self.assertRaises(ValueError):
            check_prepared(FakeAgent(), "text", {})

    def test_corpus_has_fifty_cases_and_separate_splits(self):
        corpus = Path(__file__).resolve().parent.parent / "tools/laya-eval/cases.json"
        cases = json.loads(corpus.read_text())["cases"]
        validate_cases(cases)
        self.assertEqual(len(cases), 50)
        self.assertEqual(sum(case["split"] == "development" for case in cases), 10)
        self.assertEqual(sum(bool(case["allowed"]) for case in cases), 48)
        self.assertEqual(len({case["category"] for case in cases}), 10)

    def test_duplicate_ids_are_rejected(self):
        case = {**self.case, "id": "duplicate", "split": "development"}
        with self.assertRaises(ValueError):
            validate_cases([case, case])

    def test_complete_candidates_preserve_text_and_space(self):
        case = {**self.case, "left": "Pull", "right": " Requestを確認します。"}
        _, questions = make_request(case, "candidate_en", ("none", "period", "comma"))
        self.assertEqual(questions["punctuation"]["criteria"], {
            "none": "Pull Requestを確認します。",
            "period": "Pull。 Requestを確認します。",
            "comma": "Pull、 Requestを確認します。"})

    def test_preflight_rejects_option_truncation_even_if_state_fits(self):
        class FakeAgent:
            cfg = {"head_max_len": 256}

            def prepare(self, state, questions):
                return [{"state_stats": {"truncated": False},
                         "options": {"options_distinct": 3}, "ids": [1, 2]}], []

            def tok(self, text, add_special_tokens):
                return {"input_ids": list(range(len(text)))}

        questions = {"punctuation": {"instructions": "短い質問", "criteria": {
            "comma": "長" * 49, "period": "短", "none": "短"}}}
        with self.assertRaisesRegex(ValueError, "切り詰め"):
            check_prepared(FakeAgent(), "短い本文", questions)


if __name__ == "__main__":
    unittest.main()
