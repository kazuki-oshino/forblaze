import importlib.util
from pathlib import Path
import tempfile
import unittest
import json
spec=importlib.util.spec_from_file_location('observe',Path(__file__).with_name('observe-runtime.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
class Observe(unittest.TestCase):
    def test_diagnostics_only_use_recent_typed_numeric_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            lines=[{'timestamp':9,'kind':'audioStreams','count':9},
                   {'timestamp':11,'kind':'listening','text':'保存しない本文'},
                   {'timestamp':12,'kind':'rawAudioQueuePeak','count':4,'text':'保存しない本文'},
                   {'timestamp':13,'kind':'private-title','count':7},
                   {'timestamp':14,'kind':'inputPending','count':'本文'},
                   {'timestamp':15,'kind':'resultStreams','count':float('nan')}]
            (root/'diagnostic-0.jsonl').write_text('\n'.join(json.dumps(row) for row in lines)+'\n{broken\n')
            values=a.read_diagnostics(root,10)
            self.assertEqual(values,[(11,'listening',0),(12,'rawAudioQueuePeak',4)])
            self.assertNotIn('保存しない本文',repr(values))
    def test_pid_and_memory_reject_other_processes_and_restart(self):
        self.assertEqual(a.find_pid('21 /Applications/forblaze.app/Contents/MacOS/forblaze\n22 /tmp/forblaze'),21)
        with self.assertRaises(ValueError):a.find_pid('22 /tmp/forblaze')
        with self.assertRaises(ValueError):a.find_pid('21 /Applications/forblaze.app/Contents/MacOS/forblaze\n23 /Applications/forblaze.app/Contents/MacOS/forblaze')
        self.assertEqual(a.parse_rss('12345 /Applications/forblaze.app/Contents/MacOS/forblaze'),12345)
        for value in ['123 /tmp/forblaze','','-1 /Applications/forblaze.app/Contents/MacOS/forblaze']:
            with self.assertRaises(ValueError):a.parse_rss(value)
    def test_rotated_records_are_sorted_and_oversized_files_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for index,time in [(0,3),(1,1),(2,2)]:
                (root/f'diagnostic-{index}.jsonl').write_text(json.dumps({'timestamp':time,'kind':'idle','count':0})+'\n')
            self.assertEqual([row[0] for row in a.read_diagnostics(root,0)],[1,2,3])
            (root/'diagnostic-0.jsonl').write_bytes(b'x'*65537)
            self.assertEqual(len(a.read_diagnostics(root,0)),2)
if __name__=='__main__':unittest.main()
