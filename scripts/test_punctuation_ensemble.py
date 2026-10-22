import copy
import json
import importlib.util
import math
from pathlib import Path
import unittest

from punctuation_ensemble import (PROTOCOLS, views, features, combine, fit_ridge,
                                  predict_ridge, choose, split_cases)


class EnsembleTests(unittest.TestCase):
    def setUp(self):
        self.case = {'id': 'x', 'left': 'よろしくお願い', 'right': 'します。',
                     'original': 'none', 'allowed': ['none'], 'preferred': 'none'}

    def test_prompts_never_use_gold_original_id_or_category(self):
        other = {**self.case, 'id': 'different', 'original': 'period',
                 'allowed': ['comma'], 'preferred': 'comma', 'category': 'secret'}
        for protocol in PROTOCOLS:
            with self.subTest(protocol=protocol):
                self.assertEqual(views(self.case, protocol), views(other, protocol))
                self.assertEqual(len(views(self.case, protocol)), 5)

    def test_candidates_only_change_boundary(self):
        request = views(self.case, 'fluency_en')
        self.assertEqual([v['state'] for v in request[:3]],
                         ['よろしくお願い、します。', 'よろしくお願い。します。', 'よろしくお願いします。'])

    def test_pairwise_scores_follow_semantic_labels(self):
        row = {'protocol': 'pairwise_en', 'answers': [
            {'a': 0, 'b': 1}, {'a': 0, 'b': 1}, {'a': 1, 'b': 0},
            {'false': .1, 'true': .9}, {'false': .9, 'true': .1}]}
        score = combine(row, 3)
        self.assertGreater(score[2], score[0])
        self.assertGreater(score[2], score[1])

    def test_features_are_finite_at_probability_extremes(self):
        row = {'protocol': 'fluency_en', 'answers': [{'false': 0, 'true': 1}]*5}
        self.assertTrue(all(math.isfinite(x) for x in features(row, 5)))

    def test_gate_keeps_original_on_tie_or_missing_right_context(self):
        self.assertEqual(choose(self.case, [.5, .5, 0], 0), 'none')
        self.assertEqual(choose(self.case, [.6, .4, 0], .3), 'none')
        self.assertEqual(choose({**self.case, 'right': ''}, [1, 0, 0], 0), 'none')
        self.assertEqual(choose(self.case, [.6, .4, 0], .1), 'comma')

    @unittest.skipUnless(importlib.util.find_spec('numpy'), '評価用venvのNumPyで検証する')
    def test_ridge_uses_train_statistics_and_can_predict_new_vectors(self):
        model = fit_ridge([[1, 0], [2, 0], [0, 1], [0, 2], [-1, -1], [-2, -2]],
                          ['comma', 'comma', 'period', 'period', 'none', 'none'], .1)
        self.assertEqual(max(range(3), key=lambda i: predict_ridge(model, [1.5, 0])[i]), 0)
        before = copy.deepcopy(model)
        predict_ridge(model, [100, -100])
        self.assertEqual(model, before)

    def test_frozen_corpora_have_disjoint_development_and_holdout(self):
        groups = split_cases()
        self.assertEqual(len(groups['development']), 30)
        self.assertEqual(len(groups['original']), 50)
        self.assertEqual(len(groups['holdout']), 50)
        self.assertFalse({c['id'] for c in groups['development']} & {c['id'] for c in groups['holdout']})
        self.assertEqual(sum(bool(c['allowed']) for c in groups['holdout']), 48)
        self.assertEqual(sum(c['original'] in c['allowed'] for c in groups['holdout']), 24)

    def test_normalizing_features_does_not_rewrite_raw_model_output(self):
        from run_punctuation_ensemble import run_views
        raw = {'answers': {'0': {'probabilities': {'comma': .3333, 'period': .3333, 'none': .3333}}},
               'usage': {'truncated': False}}
        class Engine:
            def predict(self, state, questions): return raw
        class Mx:
            @staticmethod
            def synchronize(): pass
        view = {'state': 'text', 'question': {'type': 'choice', 'criteria': {'comma': '', 'period': '', 'none': ''}}}
        result = run_views(Engine(), Mx(), 'laya', [view])
        self.assertEqual(result['raw'][0]['result']['answers']['0']['probabilities']['comma'], .3333)
        self.assertAlmostEqual(sum(result['answers'][0].values()), 1.)

    def test_selection_objective_can_separate_accuracy_from_harm_avoidance(self):
        from run_punctuation_ensemble import policy_rank
        safe = {'protocol': 'direct', 'kind': 'rule', 'alpha': None, 'margin': .4,
                'cv': {'acceptable': 17, 'preferred': 15, 'harmed': 0}}
        accurate = {**safe, 'cv': {'acceptable': 20, 'preferred': 18, 'harmed': 3}}
        self.assertGreater(policy_rank(safe, 'balanced'), policy_rank(accurate, 'balanced'))
        self.assertGreater(policy_rank(accurate, 'accuracy'), policy_rank(safe, 'accuracy'))

    def test_selection_rejects_duplicate_rows(self):
        from run_punctuation_ensemble import select_policy
        rows = [{'id': c['id'], 'protocol': p, 'requests': views(c, p)}
                for c in split_cases()['development'] for p in PROTOCOLS]
        data = {'backend': 'laya', 'dataset': 'development', 'rows': rows + rows[:1]}
        with self.assertRaisesRegex(ValueError, '重複'):
            select_policy(data, Path('/unused-output.json'))


if __name__ == '__main__':
    unittest.main()
