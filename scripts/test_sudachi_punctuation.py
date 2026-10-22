import importlib.util
import unittest

from sudachi_punctuation import split_punctuation, apply_punctuation, score_text, build_corpus, Analyzer, requests_for, hybrid


@unittest.skipUnless(importlib.util.find_spec('sudachipy'), 'Sudachi評価用venvで実行する')
class SudachiPunctuationTests(unittest.TestCase):
    def test_only_target_punctuation_is_removed_and_offsets_preserve_unicode(self):
        text = '😊「はい、了解です」。URLはhttps://example.comです。'
        raw, marks = split_punctuation(text)
        self.assertEqual(raw, '😊「はい了解です」URLはhttps://example.comです')
        self.assertEqual(apply_punctuation(raw, marks), text)
        with self.assertRaises(ValueError):
            apply_punctuation(raw, {999: '。'})

    def test_scoring_counts_wrong_symbol_as_false_positive_and_miss(self):
        s = score_text('甲、乙。', '甲。乙。')
        self.assertEqual((s['tp'], s['fp'], s['fn']), (1, 1, 1))
        self.assertFalse(s['exact'])
        self.assertTrue(s['lexical_exact'])
        self.assertFalse(score_text('甲乙。', '甲丙。')['lexical_exact'])

    def test_corpus_has_disjoint_splits_and_full_text_gold(self):
        c = build_corpus()
        self.assertEqual(len(c['development']), 30)
        self.assertEqual(len(c['evaluation']), 48)
        self.assertFalse({x['id'] for x in c['development']} & {x['id'] for x in c['evaluation']})
        self.assertEqual(c['development'][0]['gold'], 'こんにちは、高須クリニックです。')

    def test_candidates_do_not_split_auxiliaries_names_numbers_or_urls(self):
        a = Analyzer()
        for text, prefix in [('確認していただけますか', '確認して'),
                             ('株式会社青空に連絡します', '株式会社'),
                             ('金額は20センチです', '金額は20'),
                             ('「了解しました」と返事をしました', '「了解しました」'),
                             ('URLはhttps://example.comです', 'URLはhttps://')]:
            with self.subTest(text=text):
                plan = a.analyze(text)
                self.assertNotIn(len(prefix), [c['offset'] for c in plan['candidates']])

    def test_ordinary_noun_sequence_is_not_all_blocked(self):
        p = Analyzer().analyze('りんごみかんぶどうを買いました')
        self.assertIn(3, [c['offset'] for c in p['candidates']])

    def test_greeting_and_complete_sentence_rules(self):
        a = Analyzer()
        p = a.analyze('こんにちは高須クリニックです')
        self.assertEqual(p['rule_text'], 'こんにちは、高須クリニックです。')
        p = a.analyze('今日は休業日です明日またお越しください')
        self.assertEqual(p['rule_text'], '今日は休業日です。明日またお越しください。')

    def test_questions_depend_on_text_and_analysis_not_expected_labels(self):
        p = Analyzer().analyze('準備が整ったので出発しましょう')
        before = requests_for(p)
        p['gold'] = '漏洩させない正解'; p['id'] = 'secret'
        self.assertEqual(before, requests_for(p))
        self.assertNotIn('漏洩', str(before))

    def test_hybrid_can_abstain_and_never_edit_other_characters(self):
        p = Analyzer().analyze('こんにちは高須クリニックです')
        answers = [{'comma': .5, 'period': .5, 'none': .5} for _ in p['candidates']]
        text, changed = hybrid(p, answers, .8, .2)
        self.assertEqual(text, p['rule_text'])
        self.assertEqual(changed, 0)
        answers = [{'comma': .01, 'period': .01, 'none': .99} for _ in p['candidates']]
        text, _ = hybrid(p, answers, .8, .2)
        self.assertEqual(split_punctuation(text)[0], p['text'])


if __name__ == '__main__':
    unittest.main()
