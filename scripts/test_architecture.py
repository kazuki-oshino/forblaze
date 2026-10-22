import importlib.util
from pathlib import Path
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('architecture',Path(__file__).with_name('check-architecture.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
class Architecture(unittest.TestCase):
    def test_graph(self):
        valid={'ForblazeCore':[],'ForblazeApplication':['ForblazeCore'],'ForblazeMacOS':['ForblazeApplication','ForblazeCore']}
        a.validate_graph(valid)
        for graph in [dict(valid,ForblazeCore=['ForblazeMacOS']),dict(valid,ForblazeApplication=['ForblazeMacOS']),dict(valid,ForblazeMacOS=[])]:
            with self.assertRaises(ValueError):a.validate_graph(graph)
    def test_imports(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            p=root/'Packages/ForblazeKit/Sources/ForblazeCore/X.swift';p.parent.mkdir(parents=True)
            p.write_text('import Foundation\n');a.validate_imports(root)
            for text in ['import AppKit','@preconcurrency import Speech','import struct AVFoundation.AVAudioFormat']:
                p.write_text(text)
                with self.assertRaises(ValueError):a.validate_imports(root)
            p.write_text('import Foundation')
            ui=root/'Forblaze/Features/X.swift';ui.parent.mkdir(parents=True);ui.write_text('import ForblazeMacOS')
            with self.assertRaises(ValueError):a.validate_imports(root)
if __name__=='__main__':unittest.main()
