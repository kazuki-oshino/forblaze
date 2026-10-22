import copy
import unittest

from jev_style_2b_punctuation_eval import build_jobs, select_prompts, validate_answer, run_single
from punctuation_ensemble import split_cases


class JevStyle2BEvaluationTests(unittest.TestCase):
    def test_development_and_evaluation_have_fixed_disjoint_selection_inputs(self):
        groups = split_cases()
        development = build_jobs('develop', groups)
        evaluation = build_jobs('evaluate', groups, 'candidate_en')
        self.assertEqual(len(development), 120)
        self.assertEqual(len(evaluation), 480)
        self.assertEqual(len({j['job_id'] for j in evaluation}), 480)
        self.assertEqual(sum(j['phase'] == 'primary' for j in evaluation), 400)
        self.assertTrue(all(j['dataset'] == 'development' for j in development))
        holdout = {c['id'] for c in groups['holdout']}
        self.assertFalse(holdout & {j['id'] for j in development})

    def test_question_never_uses_gold_or_original(self):
        groups = split_cases()
        before = build_jobs('develop', groups)
        altered = copy.deepcopy(groups)
        for c in altered['development']:
            c.update(original='none', allowed=['comma'], preferred='comma')
        self.assertEqual(before, build_jobs('develop', altered))

    def test_preference_and_acceptability_are_selected_separately(self):
        a = {'preferred': 20, 'acceptable': 21, 'harmed': 1}
        b = {'preferred': 18, 'acceptable': 24, 'harmed': 0}
        self.assertEqual(select_prompts({'ja': a, 'en': b}),
                         {'preferred': 'ja', 'acceptable': 'en'})

    def result(self):
        return {'answer': 'comma', 'probabilities': {'comma': .8, 'period': .1, 'none': .1},
                'top_probability': .8, 'input_tokens': 180, 'state_tokens': 40, 'head_tokens': 140,
                'scores': {'comma': 2, 'period': 0, 'none': 0}, 'temperature': .82,
                'model': 'Jev-Style-2B-Decision-v3', 'backend': 'mlx',
                'blocks': 2, 'catalogue_overflow': False}

    def test_validation_rejects_wrong_model_and_inconsistent_token_counts(self):
        result = self.result()
        self.assertEqual(validate_answer(result), 'comma')
        for key, value in [('model', 'Jev-Style-0.8B-Decision-v3'), ('state_tokens', 50),
                           ('catalogue_overflow', True), ('blocks', 3), ('answer', 'none')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_answer({**result, key: value})

    def test_primary_timing_clears_state_cache_before_each_call(self):
        events = []
        result = self.result()
        class Inner:
            def reset(self): events.append('reset')
        class Engine:
            engine = Inner()
            last_timing = {'state_reused': False}
            def decide(self, state, question):
                events.append('decide')
                return result
        class Mx:
            @staticmethod
            def synchronize(): events.append('sync')
        row = run_single(Engine(), Mx(), {'state': 'test', 'question': {}})
        self.assertEqual(events, ['reset', 'sync', 'decide', 'sync'])
        self.assertEqual(row['result'], result)
        self.assertFalse(row['timing']['state_reused'])


if __name__ == '__main__':
    unittest.main()
