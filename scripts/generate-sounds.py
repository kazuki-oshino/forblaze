#!/usr/bin/env python3
"""forblaze専用の短い2音のベルを合成する（録音素材や外部音源は使用しない）。"""
from pathlib import Path
import math
import struct
import subprocess
import wave

ROOT=Path(__file__).resolve().parent.parent
RATE=44100

def synthesize(notes,duration,offset):
    samples=[]
    for index in range(round(duration*RATE)):
        time=index/RATE;value=0.0
        for number,frequency in enumerate(notes):
            age=time-number*offset
            if age<0 or age>0.29:continue
            attack=min(age/0.028,1)**2
            release=min(max((0.29-age)/0.075,0),1)**2
            envelope=attack*math.exp(-age/0.105)*release
            phase=2*math.pi*frequency*age
            tone=math.sin(phase)+0.045*math.sin(phase*2.005)+0.008*math.sin(phase*3)
            value+=0.12*envelope*tone
        samples.append(value)
    return struct.pack('<'+str(len(samples))+'f',*samples)

def main():
    output=ROOT/'Forblaze/Resources/Sounds';output.mkdir(parents=True,exist_ok=True)
    for name,notes,duration,offset in (
        ('start',(329.628,493.883),0.44,0.115),
        ('stop',(493.883,329.628),0.40,0.09),
    ):
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y',
            '-f','f32le','-ar',str(RATE),'-ac','1','-i','pipe:0',
            '-af','highpass=f=70,lowpass=f=1800,afade=t=out:st='+str(duration-0.025)+':d=0.025',
            '-map_metadata','-1','-fflags','+bitexact','-flags:a','+bitexact',
            '-c:a','pcm_s16le',str(output/('recording-'+name+'.wav'))],input=synthesize(notes,duration,offset),check=True)
        if name=='start':
            # 波形を変えず、量子化後に0が続く末尾だけを1msまで短くする。
            path=output/('recording-'+name+'.wav')
            with wave.open(str(path),'rb') as handle:
                params=handle.getparams();frames=handle.readframes(handle.getnframes())
            samples=struct.unpack('<'+str(len(frames)//2)+'h',frames)
            last_nonzero=max(i for i,sample in enumerate(samples) if sample!=0)
            end=min(len(samples),last_nonzero+1+round(RATE*0.001))
            with wave.open(str(path),'wb') as handle:
                handle.setparams(params);handle.writeframes(frames[:end*2])
    print('開始・終了音を再生成しました: '+str(output))

if __name__=='__main__':main()
