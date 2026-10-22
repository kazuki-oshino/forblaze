import copy
import json
from pathlib import Path
import tempfile
import unittest

from jev_punctuation_eval import (build_jobs, decode_result, decode_rows, load_key, read_checkpoint,
                                  run_request, safe_json)
from punctuation_eval import make_request, ORDERS


class Response:
    def __init__(self, status, data=None, headers=None):
        self.status_code = status
        self.data = data
        self.headers = headers or {}

    def json(self):
        return self.data


class Client:
    def __init__(self, *responses):
        self.responses = iter(responses)
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return next(self.responses)


class JevEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.answer = {"type": "choice", "choice": "comma", "confidence": .8,
                       "probabilities": {"comma": .8, "period": .1, "none": .1}}
        self.result = {"model": "jev-1.13.0", "answers": {"q": self.answer},
                       "usage": {"input_tokens": 100, "output_tokens": 20}}

    def test_key_parser_handles_export_quotes_and_does_not_execute(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.env'
            path.write_text('OTHER=$(echo unwanted)\nexport TYPESAFE_API_KEY="fake-key" # comment\n')
            self.assertEqual(load_key(path), 'fake-key')
            path.write_text('TYPESAFE_API_KEY="$(do-not-execute)"\n')
            self.assertEqual(load_key(path), '$(do-not-execute)')

    def test_invalid_key_error_never_echoes_value(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.env'
            path.write_text('TYPESAFE_API_KEY="sensitive unclosed\n')
            with self.assertRaises(ValueError) as error:
                load_key(path)
            self.assertNotIn('sensitive', str(error.exception))

    def test_jev_decodes_without_fabricating_laya_truncation_field(self):
        before = copy.deepcopy(self.result)
        self.assertEqual(decode_result(self.result, ['q'], 'jev-1.13.0'), {'q': 'comma'})
        self.assertEqual(self.result, before)

    def test_api_probability_rounding_is_preserved(self):
        self.result['answers']['q']['probabilities'] = {'comma': .56, 'period': .04, 'none': .39}
        self.assertEqual(decode_result(self.result, ['q'], 'jev-1.13.0'), {'q': 'comma'})
        self.assertAlmostEqual(sum(self.result['answers']['q']['probabilities'].values()), .99)
        self.result['answers']['q']['probabilities']['comma'] = .5
        with self.assertRaises(ValueError):
            decode_result(self.result, ['q'], 'jev-1.13.0')

    def test_malformed_answers_and_unexpected_model_are_rejected(self):
        for change in ('model', 'missing', 'probabilities', 'choice', 'confidence', 'usage'):
            result = copy.deepcopy(self.result)
            if change == 'model': result['model'] = 'different-model'
            if change == 'missing': result['answers'] = {}
            if change == 'probabilities': result['answers']['q']['probabilities']['comma'] = float('nan')
            if change == 'choice': result['answers']['q']['choice'] = 'unknown'
            if change == 'confidence': result['answers']['q']['confidence'] = -1
            if change == 'usage': result['usage']['input_tokens'] = -1
            with self.subTest(change=change), self.assertRaises(ValueError):
                decode_result(result, ['q'], 'jev-1.13.0')

    def test_api_choice_is_preserved_and_probability_disagreement_is_flagged(self):
        self.result['answers']['q'].update(choice='period',
            probabilities={'comma': .45, 'period': .44, 'none': .11})
        record = {'result': self.result, 'items': {'q': {'id': '30'}},
                  'phase': 'repeat', 'job_id': 'example', 'elapsed_ms': 100}
        row = decode_rows(record)[0]
        self.assertEqual(row['choice'], 'period')
        self.assertFalse(row['choice_is_argmax'])

    def test_retry_after_is_honored_and_auth_is_not_persisted(self):
        client = Client(Response(429, headers={'retry-after': '3'}), Response(200, self.result))
        sleeps = []
        result = run_request(client, {'questions': {}}, 'fake-key', sleep=sleeps.append)
        self.assertEqual(sleeps, [3])
        self.assertEqual(result['retry_statuses'], [429])
        self.assertNotIn('fake-key', json.dumps(result))
        self.assertEqual(client.calls[0][1]['headers']['Authorization'], 'Bearer fake-key')

    def test_auth_errors_are_not_retried_or_echoed(self):
        client = Client(Response(401, {'message': 'fake-key'}))
        with self.assertRaises(RuntimeError) as error:
            run_request(client, {}, 'fake-key')
        self.assertNotIn('fake-key', str(error.exception))
        self.assertEqual(len(client.calls), 1)

    def test_retry_is_bounded(self):
        client = Client(*(Response(529) for _ in range(4)))
        sleeps = []
        with self.assertRaises(RuntimeError):
            run_request(client, {}, 'fake-key', sleep=sleeps.append)
        self.assertEqual(sleeps, [1, 2, 4])

    def test_secret_guard_rejects_accidental_persistence(self):
        with self.assertRaises(ValueError):
            safe_json({'response': 'prefix fake-key suffix'}, 'fake-key')

    def test_same_corpus_prompts_and_orders_are_sent_without_gold(self):
        cases = json.loads((Path(__file__).resolve().parent.parent /
                            'tools/laya-eval/cases.json').read_text())['cases']
        jobs = build_jobs(cases, 'jev-1.13.0')
        self.assertEqual(len(jobs), 502)
        self.assertEqual(sum(len(job['items']) for job in jobs), 1602)
        for job in jobs:
            for key, item in job['items'].items():
                case = next(case for case in cases if case['id'] == item['id'])
                state, questions = make_request(case, item['prompt'], ORDERS[item['order_index']])
                self.assertEqual(job['request']['state'], state)
                self.assertEqual(job['request']['questions'][key], questions['punctuation'])

    def test_resume_rejects_changed_config_and_duplicate_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'checkpoint.jsonl'
            path.write_text(json.dumps({'metadata': {'hash': 'original'}}) + '\n')
            self.assertEqual(read_checkpoint(path, {'hash': 'original'}), [])
            with self.assertRaises(ValueError):
                read_checkpoint(path, {'hash': 'changed'})
            with path.open('a') as stream:
                stream.write('{"job_id":"one"}\n{"job_id":"one"}\n')
            with self.assertRaises(ValueError):
                read_checkpoint(path, {'hash': 'original'})

    def test_resume_allows_logging_fix_but_retains_old_script_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'checkpoint.jsonl'
            path.write_text(json.dumps({'metadata': {'script_sha256': 'before', 'model': 'fixed'}}) + '\n')
            self.assertEqual(read_checkpoint(path, {'script_sha256': 'after', 'model': 'fixed'}), [])
            self.assertEqual(json.loads(path.read_text())['metadata']['script_sha256'], 'before')


if __name__ == '__main__':
    unittest.main()
