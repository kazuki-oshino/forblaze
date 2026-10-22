import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from jev_style_punctuation_eval import (decode_local, local_question, local_jobs,
                                       verify_files)
from punctuation_eval import make_request, ORDERS


class JevStyleEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.result = {'answer': 'comma', 'probabilities': {'comma': .8, 'period': .1, 'none': .1},
                       'top_probability': .8, 'input_tokens': 180, 'head_tokens': 140,
                       'scores': {'comma': 2, 'period': 0, 'none': 0}, 'temperature': .88}

    def test_adapter_preserves_text_options_and_order_without_gold(self):
        case = {'left': 'こんにちは', 'right': '高須クリニックです。', 'allowed': ['comma']}
        for prompt in ('ja', 'en', 'candidate_ja', 'candidate_en'):
            for order in ORDERS:
                state, questions = make_request(case, prompt, order)
                adapted = local_question(questions['punctuation'])
                self.assertEqual(adapted['ins'], questions['punctuation']['instructions'])
                self.assertEqual(list(adapted['crit']), list(order))
                self.assertEqual(adapted['crit'], questions['punctuation']['criteria'])
                self.assertEqual(adapted['t'], 'choice')
                case['allowed'] = ['period']
                self.assertEqual(make_request(case, prompt, order)[0], state)

    def test_decoding_keeps_original_result(self):
        before = copy.deepcopy(self.result)
        self.assertEqual(decode_local(self.result), 'comma')
        self.assertEqual(before, self.result)

    def test_bad_probabilities_choice_and_budget_are_rejected(self):
        for field, value in [('answer', 'unknown'), ('input_tokens', 25601),
                             ('head_tokens', 2049), ('head_tokens', 181),
                             ('input_tokens', 0), ('option_chunks', 2),
                             ('top_probability', .5), ('temperature', 0),
                             ('scores', {'comma': float('nan'), 'period': 0, 'none': 0}),
                             ('probabilities', {'comma': .2, 'period': .2, 'none': .2})]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                decode_local({**self.result, field: value})

    def test_choice_must_match_highest_probability(self):
        with self.assertRaises(ValueError):
            decode_local({**self.result, 'answer': 'period'})

    def test_protocol_has_same_fifty_cases_and_extended_warmup(self):
        path = Path(__file__).resolve().parent.parent / 'tools/laya-eval/cases.json'
        jobs = local_jobs(json.loads(path.read_text())['cases'])
        self.assertEqual(len(jobs), 506)
        self.assertEqual(len({job['job_id'] for job in jobs}), 506)
        self.assertEqual(sum(len(job['items']) for job in jobs), 1606)
        self.assertEqual(sum(job['phase'] == 'warmup' for job in jobs), 6)

    def test_manifest_rejects_changed_weights_before_runtime_import(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bf16').mkdir()
            files = {'jev_style_decision_mlx.py': b'runtime', 'bf16/model.safetensors': b'weights',
                     'bf16/config.json': b'{}', 'bf16/tokenizer.json': b'{}',
                     'readout_config.json': b'{}', 'release_config.json': b'{}'}
            for name, data in files.items(): (root / name).write_bytes(data)
            manifest = {'files': {name: {'sha256': hashlib.sha256(data).hexdigest()}
                                  for name, data in files.items()}}
            # 未取得の8bit版は今回の検証対象外。
            manifest['files']['8bit/model.safetensors'] = {'sha256': 'unused'}
            (root / 'manifest.json').write_text(json.dumps(manifest))
            self.assertEqual(len(verify_files(root, 'bf16')), 6)
            (root / 'bf16/model.safetensors').write_bytes(b'changed')
            with self.assertRaises(ValueError): verify_files(root, 'bf16')

    def test_manifest_cannot_escape_model_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'manifest.json').write_text(json.dumps({'files': {
                'bf16/../../outside': {'sha256': 'bad'}}}))
            with self.assertRaises(ValueError): verify_files(root, 'bf16')


if __name__ == '__main__':
    unittest.main()
