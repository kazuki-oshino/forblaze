import json
import unittest

from speech_candidate_eval import parse_log, make_cases, make_request, effective_choice


def fixture():
    return '''forblaze 認識候補の調査ログ / session=S1 / build=test
=== #1 [途中] 2026-10-14T11:00:01.000+09:00 / 音声=0.000〜3.000秒 ===
第一候補: "前文。痴漢します"
APIのalternatives件数: 1
候補 1/1: "前文。痴漢します"
=== #2 [確定] 2026-10-14T11:00:02.000+09:00 / 音声=0.000〜1.000秒 ===
第一候補: "前文。"
APIのalternatives件数: 1
候補 1/1: "前文。"
=== #3 [確定] 2026-10-14T11:00:02.001+09:00 / 音声=1.000〜2.000秒 ===
第一候補: "痴漢"
  部分 "痴漢" / 信頼度=0.53 / 音声=1.000〜2.000秒
APIのalternatives件数: 2
候補 1/2: "痴漢"
候補 2/2: "置換"
=== #4 [確定] 2026-10-14T11:00:02.002+09:00 / 音声=2.000〜3.000秒 ===
第一候補: "します\\n終わり"
APIのalternatives件数: 1
候補 1/1: "します\\n終わり"
終了: 受信=4 / 待機上限による欠落=0 / 書込失敗=0
'''


class SpeechCandidateEvalTests(unittest.TestCase):
    def test_parser_preserves_order_unicode_newlines_and_provenance(self):
        session=parse_log(fixture(), 'sample.log')
        self.assertEqual(session['events'][2]['alternatives'], ['痴漢', '置換'])
        self.assertEqual(session['events'][3]['best'], 'します\n終わり')
        self.assertEqual(session['received'], 4)
        self.assertEqual(len(session['sha256']), 64)
        self.assertEqual(session['events'][2]['confidence_runs'][0]['confidence'], .53)

    def test_cases_use_final_ranges_not_global_word_replacement(self):
        cases=make_cases([parse_log(fixture(), 'sample.log')], 'test')
        self.assertEqual(len(cases), 1)
        self.assertEqual(cases[0]['left'], '前文。')
        self.assertEqual(cases[0]['right'], 'します\n終わり')
        self.assertEqual(cases[0]['candidates'], ['痴漢', '置換'])

    def test_incomplete_or_dropped_sessions_are_not_scored_as_complete(self):
        source=fixture()
        for value in [source.replace('受信=4', '受信=5'), source.replace('欠落=0', '欠落=1'),
                      source[:source.index('=== #4')], source.replace('2.000〜3.000秒', '2.000〜2.500秒')]:
            session=parse_log(value, 'sample.log')
            self.assertEqual(make_cases([session], 'test'), [])

    def test_prompt_hides_labels_confidence_and_target_first_choice(self):
        case=make_cases([parse_log(fixture(), 'sample.log')], 'test')[0]
        case.update(allowed=[1], rationale='秘密の正解', confidence=.53)
        for context in ['local', 'session', 'recent']:
            state, questions, mapping=make_request(case, context, 'ja', [2,1,0])
            self.assertIn('【候補】', state)
            self.assertNotIn('痴漢', state)
            self.assertNotIn('秘密', json.dumps(questions, ensure_ascii=False))
            self.assertNotIn('0.53', json.dumps(questions))
            self.assertEqual(mapping, {'a':None, 'b':1, 'c':0})

    def test_history_contains_only_prior_sessions(self):
        previous=parse_log(fixture().replace('session=S1', 'session=S0'), 'before.log')
        current=parse_log(fixture(), 'now.log')
        future=parse_log(fixture().replace('session=S1', 'session=S2').replace('前文。', '未来の正解'), 'later.log')
        case=make_cases([previous,current,future], 'test')[1]
        state, _, _=make_request(case, 'recent', 'en', [0,1,2])
        self.assertIn('前文。痴漢します', state)
        self.assertNotIn('未来', state)

    def test_abstention_and_margin_gate_keep_apple_choice(self):
        self.assertEqual(effective_choice(None, .9, 0), 0)
        self.assertEqual(effective_choice(1, .1, .2), 0)
        self.assertEqual(effective_choice(1, .3, .2), 1)

    def test_phrase_options_change_only_the_target_and_keep_the_same_context(self):
        case=make_cases([parse_log(fixture(), 'sample.log')], 'test')[0]
        word,_,_=make_request(case,'session','en',[0,1,2])
        phrase,questions,mapping=make_request(case,'session','en',[0,1,2],'phrase')
        self.assertEqual(word,phrase)
        self.assertEqual(questions['selection']['criteria']['a'],'前文。痴漢します\n終わり')
        self.assertEqual(questions['selection']['criteria']['b'],'前文。置換します\n終わり')
        self.assertEqual(mapping,{'a':0,'b':1,'c':None})


if __name__=='__main__':unittest.main()
