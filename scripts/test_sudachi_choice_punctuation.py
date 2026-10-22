import unittest
from sudachi_choice import choice_requests


class ChoiceTests(unittest.TestCase):
    def test_only_target_boundary_changes_and_other_rule_punctuation_is_retained(self):
        plan = {'text': 'こんにちは高須です次です', 'rule_marks': {5:'、',9:'。',12:'。'},
                'candidates': [{'offset':5}], 'gold':'絶対に入力しない'}
        request = choice_requests(plan)[0]
        self.assertEqual(request['question']['criteria'], {'comma':'こんにちは、高須です。次です。',
            'period':'こんにちは。高須です。次です。', 'none':'こんにちは高須です。次です。'})
        self.assertNotIn('絶対',str(request))
        self.assertEqual(plan['rule_marks'], {5:'、',9:'。',12:'。'})


if __name__ == '__main__': unittest.main()
