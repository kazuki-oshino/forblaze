import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4

spec=importlib.util.spec_from_file_location('input_latency',Path(__file__).with_name('input-latency.py'))
report=importlib.util.module_from_spec(spec);spec.loader.exec_module(report)

class InputLatency(unittest.TestCase):
    def test_reports_fast_failures_and_actual_audio_sizes_without_text(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);session=str(uuid4());rows=self.records()
            rows += [
                self.details(session,'input',{'total':200,'queue':100,'issue':100},9.1),
                self.details(session,'inputFailures',{'total':50,'queue':0,'issue':50,'completed':0,'localizedStage':3,'localizedReason':7,'localizedWaits':5,'localizedIssued':0,'localizedFallback':0,'text':'保存しない'},9.2),
                self.details(session,'inputSummary',{'localizedAttempts':1,'localizedCompletions':0,'localizedUnavailable':0,'localizedStops':1,'localizedWaits':5,'correctionEvents':1,'maximumRewrite':1},9.3),
                self.details(session,'speech',{'timelineValid':0,'unmeasuredResults':0,'frameLengthP50':960,'frameLengthP95':960,'frameLengthMax':960,'frameLengthCount':2},1)]
            (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows)))
            summary=report.read_summaries(root)[0]
            self.assertNotIn('保存しない',repr(summary))
            self.assertEqual(summary['inputFailures']['samples'][0]['values']['localizedWaits'],5)
            formatted=report.format_summary(summary)
            self.assertIn('選択確認',formatted)
            self.assertIn('期限超過',formatted)
            self.assertIn('実フレーム長',formatted)
            self.assertIn('試行 1',formatted)

    def test_reports_preserved_suffix_without_requiring_new_fields_in_old_sessions(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);rows=self.records()
            rows += [{'timestamp':9.2,'kind':'inputLocalizedPublications','count':1,'milliseconds':0},
                     {'timestamp':9.3,'kind':'inputPreservedCharacters','count':85,'milliseconds':0}]
            (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows)))
            self.assertIn('範囲置換 1回 / 削除・再入力を省いた末尾 85文字',report.format_summary(report.read_summaries(root)[0]))
    def details(self,session,stage,values,stamp=1):
        return {'timestamp':stamp,'kind':'latencyDetails','count':1,'milliseconds':0,
                'details':{'session':session,'stage':stage,'samples':[{'sequence':1,'values':values}]}}

    def test_correlates_speech_and_slow_input_by_session_across_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);session=str(uuid4());rows=self.records(10)
            speech=self.details(session,'speech',{'timelineValid':1,'unmeasuredResults':0,'firstSpeechToResult':1200},1)
            unrelated=self.details(str(uuid4()),'speech',{'timelineValid':1,'unmeasuredResults':0,'firstSpeechToResult':9000},2)
            trace=self.details(session,'input',{'total':257,'queue':183,'issue':74,'scheduledWait':150,'timerOverrun':33,'text':'保存しない'},19.5)
            (root/'diagnostic-1.jsonl').write_text('\n'.join(map(json.dumps,[speech,unrelated]+rows[:6])))
            (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows[6:]+[trace])))
            summary=report.read_summaries(root)[0]
            self.assertEqual(summary['speechDetails']['samples'][0]['values']['firstSpeechToResult'],1200)
            self.assertEqual(summary['inputDetails']['samples'][0]['values']['total'],257)
            self.assertNotIn('保存しない',repr(summary))
            self.assertIn('発話先頭',report.format_summary(summary))
            self.assertIn('タイマー超過 33.00',report.format_summary(summary))

    def test_legacy_or_missing_measurements_are_not_displayed_as_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);rows=self.records()
            (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows)))
            summary=report.read_summaries(root)[0]
            self.assertIn('詳細計測なし',report.format_summary(summary))
            session=str(uuid4())
            rows += [self.details(session,'speech',{'timelineValid':0,'unmeasuredResults':2},0),
                     self.details(session,'input',{'total':200,'queue':200,'issue':0},9.5)]
            (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows)))
            formatted=report.format_summary(report.read_summaries(root)[0])
            self.assertIn('発話先頭 → 初回認識結果: 未計測',formatted)
            self.assertIn('時刻対応: 欠落または不連続',formatted)

    def test_invalid_detail_records_do_not_destroy_legacy_summary(self):
        bad_values=[{'total':float('nan')},{'total':True},{'total':-1},{'timelineValid':2},{'interimCount':513},
                    {'interimP50':30,'interimP95':20,'interimMax':50,'interimCount':2}]
        for fields in bad_values:
            with self.subTest(fields=fields),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);rows=self.records()
                rows.append(self.details(str(uuid4()),'input',fields,9.5))
                (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows)))
                summary=report.read_summaries(root)[0]
                self.assertNotIn('inputDetails',summary)

    def test_empty_slow_sample_list_means_no_threshold_exceeded(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);rows=self.records();row=self.details(str(uuid4()),'input',{},9.5)
            row['details']['samples']=[];row['count']=0;rows.append(row)
            (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows)))
            self.assertIn('長い入力待ち: 対象なし',report.format_summary(report.read_summaries(root)[0]))

    def records(self,start=1):
        rows=[]
        for prefix in ('inputQueueWait','inputIssueDuration','recognitionToIssue'):
            for suffix,value in [('P50',10),('P95',60),('Max',80)]:
                rows.append({'timestamp':start+len(rows),'kind':prefix+suffix,'count':12,'milliseconds':value,'text':'保持しない本文'})
        for kind,count in [('inputPublications',20),('inputPartialPublications',1),('inputRewrittenCharacters',3)]:
            rows.append({'timestamp':start+len(rows),'kind':kind,'count':count,'milliseconds':0})
        return rows

    def test_reads_rotated_numeric_summaries_without_retaining_text(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);rows=self.records()
            (root/'diagnostic-1.jsonl').write_text('\n'.join(map(json.dumps,rows[:5])))
            (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows[5:]))+'\n{broken')
            values=report.read_summaries(root)
            self.assertEqual(len(values),1)
            self.assertEqual(values[0]['inputQueueWaitP95'],{'count':12,'milliseconds':60})
            self.assertEqual(values[0]['inputPublications']['count'],20)
            self.assertNotIn('保持しない本文',repr(values))
            self.assertNotIn('text',repr(values))

    def test_partial_rotation_and_incomplete_latest_session_do_not_mix(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            rows=self.records()[-3:]+self.records(30)+self.records(60)[:4]
            (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows)))
            values=report.read_summaries(root)
            self.assertEqual(len(values),1)
            self.assertEqual(values[0]['timestamp'],41)

    def test_invalid_numbers_and_unknown_fields_are_rejected(self):
        for field,value in [('milliseconds',float('nan')),('milliseconds',float('inf')),('milliseconds',-1),('milliseconds',True),('count','本文'),('count',True),('count',1000001),('timestamp',float('nan'))]:
            with self.subTest(field=field,value=value),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);rows=self.records();rows[1][field]=value
                (root/'diagnostic-0.jsonl').write_text('\n'.join(map(json.dumps,rows)))
                self.assertEqual(report.read_summaries(root),[])

    def test_symlink_and_oversized_log_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'private.jsonl'
            source.write_text('\n'.join(map(json.dumps,self.records())))
            (root/'diagnostic-0.jsonl').symlink_to(source)
            (root/'diagnostic-1.jsonl').write_bytes(b'x'*65537)
            self.assertEqual(report.read_summaries(root),[])

if __name__=='__main__':unittest.main()
