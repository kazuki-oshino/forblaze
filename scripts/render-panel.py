#!/usr/bin/env python3
"""本番のSwiftUIパネルを偽物の状態で描画し、build/panel-previewへ保存する。"""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parent.parent
subprocess.run(['swift','build','--package-path',str(ROOT/'Packages/ForblazeKit')],cwd=ROOT,check=True)
folder=Path(subprocess.check_output(['swift','build','--package-path',str(ROOT/'Packages/ForblazeKit'),'--show-bin-path'],text=True).strip())
output=ROOT/'build/panel-preview';output.mkdir(parents=True,exist_ok=True)
objects=sorted((folder/'ForblazeCore.build').glob('*.o'))+sorted((folder/'ForblazeApplication.build').glob('*.o'))
sources=[ROOT/'Forblaze/Features/Dictation/DictationViewModel.swift',ROOT/'Forblaze/Presentation/StatusPanelView.swift',ROOT/'tools/panel-preview/main.swift']
subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-target','arm64-apple-macosx26.0','-I',str(folder/'Modules'),*[str(p) for p in sources+objects],'-o',str(output/'render-panel')],cwd=ROOT,check=True)
subprocess.run([str(output/'render-panel'),str(output)],cwd=ROOT,check=True)
print('描画結果: '+str(output))
