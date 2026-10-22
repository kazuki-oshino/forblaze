#!/usr/bin/env python3
"""本番のMetal描画とパネルを、マイク・認識・キー監視なしで検証する。"""
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parent.parent
subprocess.run(['swift','build','--package-path',str(ROOT/'Packages/ForblazeKit')],cwd=ROOT,check=True)
folder=Path(subprocess.check_output(['swift','build','--package-path',str(ROOT/'Packages/ForblazeKit'),'--show-bin-path'],text=True).strip())
output=ROOT/'build/blaze-preview';output.mkdir(parents=True,exist_ok=True)
objects=sorted((folder/'ForblazeCore.build').glob('*.o'))+sorted((folder/'ForblazeApplication.build').glob('*.o'))
sources=[ROOT/'Forblaze/Features/Dictation/DictationViewModel.swift',ROOT/'Forblaze/Presentation/StatusPanelView.swift',ROOT/'Forblaze/Presentation/StatusPanelController.swift']
sources+=sorted((ROOT/'Forblaze/Presentation').glob('Blaze*.swift'))+[ROOT/'tools/blaze-preview/main.swift']
executable=output/'blaze-preview'
subprocess.run(['swiftc','-O','-swift-version','6','-parse-as-library','-target','arm64-apple-macosx26.0','-I',str(folder/'Modules'),*[str(p) for p in sources+objects],'-o',str(executable)],cwd=ROOT,check=True)
subprocess.run([str(executable),str(output),*sys.argv[1:]],cwd=ROOT,check=True)
print('描画結果: '+str(output))
