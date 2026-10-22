import importlib.util
from pathlib import Path
import tempfile
import unittest
import plistlib
import shutil
spec=importlib.util.spec_from_file_location('install',Path(__file__).with_name('install-app.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
def make_app(path,marker):
    (path/'Contents/MacOS').mkdir(parents=True)
    (path/'Contents/MacOS/forblaze').write_text(marker)
    (path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.kazuki-oshino.forblaze'}))
class Install(unittest.TestCase):
    def test_success_and_failures_preserve_old(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source/forblaze.app';dest=root/'Applications/forblaze.app'
            make_app(source,'new');make_app(dest,'old')
            def bad_copy(src,dst):
                shutil.copytree(src,dst);raise OSError('copy failure')
            def bad_verify(path): raise ValueError('invalid signature')
            def bad_move(src,dst):
                if src.name.startswith('.forblaze-stage'):raise OSError('move failure')
                src.rename(dst)
            for kwargs in [{'copy':bad_copy},{'verify':bad_verify},{'move':bad_move}]:
                with self.assertRaises((OSError,ValueError)):
                    a.install(source,dest,allowed_parent=dest.parent,verify=lambda p:None,**{k:v for k,v in kwargs.items() if k!='verify'}) if 'verify' not in kwargs else a.install(source,dest,allowed_parent=dest.parent,**kwargs)
                self.assertEqual((dest/'Contents/MacOS/forblaze').read_text(),'old')
            a.install(source,dest,allowed_parent=dest.parent,verify=lambda p:None)
            self.assertEqual((dest/'Contents/MacOS/forblaze').read_text(),'new')
    def test_invalid_destination_and_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source/forblaze.app';make_app(source,'new')
            for name in ['another.app','anything.app']:
                with self.assertRaises(ValueError):a.install(source,root/name,allowed_parent=root,verify=lambda p:None)
            (source/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'other'}))
            with self.assertRaises(ValueError):a.install(source,root/'forblaze.app',allowed_parent=root,verify=lambda p:None)
if __name__=='__main__':unittest.main()
