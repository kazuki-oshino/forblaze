import unittest
import tempfile
import json
from pathlib import Path
from jev_usage import summarize, read_events


class JevUsageSummaryTests(unittest.TestCase):
    def event(self, request_id, phase='request', **values):
        return dict(schemaVersion=1, requestID=request_id, phase=phase,
                    timestamp=1000, model='jev-1.13.0', questionCount=3, **values)

    def test_pairs_calls_counts_batch_once_and_preserves_unknowns(self):
        response=self.event('a', 'response', outcome='success', usage=dict(inputTokens=657, outputTokens=111))
        events=[self.event('a'),response,response,self.event('b'),
                self.event('b','response',outcome='cancelled'),self.event('c')]
        result=summarize(events)
        self.assertEqual(result['api_calls'],3)
        self.assertEqual(result['questions'],9)
        self.assertEqual(result['input_tokens'],657)
        self.assertEqual(result['output_tokens'],111)
        self.assertEqual(result['usage_unknown_calls'],2)
        self.assertEqual(result['unfinished_calls'],1)
        self.assertAlmostEqual(result['known_usage_estimated_usd'],657*.042/1_000_000)

    def test_keeps_rejected_answer_usage_and_orphaned_responses_after_rotation(self):
        result=summarize([self.event('a','response',outcome='invalidResponse',usage=dict(inputTokens=420,outputTokens=41))])
        self.assertEqual(result['api_calls'],1)
        self.assertEqual(result['missing_request_events'],1)
        self.assertEqual(result['input_tokens'],420)

    def test_unknown_model_is_not_priced_using_jev_rate(self):
        response=self.event('a','response',usage=dict(inputTokens=100,outputTokens=10))
        response['model']='future-model'
        result=summarize([response])
        self.assertEqual(result['unpriced_calls'],1)
        self.assertEqual(result['known_usage_estimated_usd'],0)

    def test_filters_by_request_time_not_response_time(self):
        request=self.event('a')
        response=self.event('a','response',usage=dict(inputTokens=420,outputTokens=41))
        response['timestamp']=2000
        self.assertEqual(summarize([request,response],since=1500)['api_calls'],0)

    def test_tolerates_partial_last_line_but_reports_it(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'requests-0.jsonl'
            path.write_text(json.dumps(self.event('a'))+'\n{"requestID":')
            (Path(directory)/'unrelated.jsonl').write_text('do not parse')
            events,invalid=read_events(Path(directory))
            self.assertEqual(len(events),1)
            self.assertEqual(invalid,1)

    def test_empty_logs_do_not_imply_historical_zero_cost(self):
        result=summarize([])
        self.assertEqual(result['api_calls'],0)
        self.assertIsNone(result['first_request_at'])


if __name__=='__main__':
    unittest.main()
