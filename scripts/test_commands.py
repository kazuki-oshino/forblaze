import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys
spec=importlib.util.spec_from_file_location('verify',Path(__file__).with_name('verify.py'))
v=importlib.util.module_from_spec(spec); sys.modules['verify']=v; spec.loader.exec_module(v)
class Commands(unittest.TestCase):
    def test_pass_fail_and_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'runner.py'
            for code,text in [(0,'Test run with 2 tests passed'),(1,'Test run with 2 tests failed'),(0,'Test run with 0 tests passed'),(0,'unrelated output')]:
                p.write_text(f'import sys\nprint({text!r})\nsys.exit({code})\n')
                if code==0 and '2 tests passed' in text:
                    self.assertEqual(v.run_tests([sys.executable,str(p)]),2)
                else:
                    with self.assertRaises(v.VerificationError): v.run_tests([sys.executable,str(p)])
    def test_module_filter(self):
        self.assertIn("ForblazeCoreTests\\.TriggerBindingTests",v.test_command("core","TriggerBindingTests"))
    def test_invalid_suite(self):
        with self.assertRaises(v.VerificationError): v.test_command('invalid','x')
if __name__=='__main__': unittest.main()
