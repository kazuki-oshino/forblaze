#!/usr/bin/env python3
"""承認済みの原画からmacOSのAppIcon各サイズを生成する。画像生成APIは呼ばない。"""
from pathlib import Path
import json
import subprocess

ROOT=Path(__file__).resolve().parent.parent
SOURCE=ROOT/'Forblaze/Resources/IconSource/forblaze-master.png'
CATALOG=ROOT/'Forblaze/Resources/Assets.xcassets'
OUTPUT=CATALOG/'AppIcon.appiconset'

def main():
    OUTPUT.mkdir(parents=True,exist_ok=True)
    info={'author':'xcode','version':1}
    (CATALOG/'Contents.json').write_text(json.dumps({'info':info},indent=2)+'\n')
    images=[]
    for points in (16,32,128,256,512):
        for scale in (1,2):
            pixels=points*scale
            filename=f'icon_{points}x{points}@{scale}x.png'
            subprocess.run(['sips','--resampleHeightWidth',str(pixels),str(pixels),str(SOURCE),
                            '--out',str(OUTPUT/filename)],check=True,stdout=subprocess.DEVNULL)
            images.append({'filename':filename,'idiom':'mac','scale':f'{scale}x','size':f'{points}x{points}'})
    (OUTPUT/'Contents.json').write_text(json.dumps({'images':images,'info':info},indent=2)+'\n')
    print('AppIconの10サイズを生成しました: '+str(OUTPUT))

if __name__=='__main__':main()
