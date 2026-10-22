"""同梱する効果音の長さ・音量・継ぎ目・音程の向きとビルドへの収録を検証する。"""
from pathlib import Path
import array
import math
import sys
import unittest
import wave

ROOT=Path(__file__).resolve().parent.parent
SOUNDS=ROOT/'Forblaze/Resources/Sounds'

def read_sound(name):
    with wave.open(str(SOUNDS/('recording-'+name+'.wav')),'rb') as handle:
        assert handle.getnchannels()==1 and handle.getsampwidth()==2
        assert handle.getframerate()==44100
        samples=array.array('h',handle.readframes(handle.getnframes()))
    if sys.byteorder!='little':samples.byteswap()
    return [s/32768 for s in samples]

def energy(samples,frequency,begin,end):
    start=int(begin*44100);stop=int(end*44100)
    return abs(sum(samples[i]*complex(math.cos(2*math.pi*frequency*i/44100),math.sin(2*math.pi*frequency*i/44100)) for i in range(start,stop)))

class SoundTests(unittest.TestCase):
    def test_start_cue_does_not_wait_through_unused_silent_tail(self):
        samples=read_sound('start')
        last_nonzero=max(i for i,sample in enumerate(samples) if sample!=0)
        self.assertLessEqual((len(samples)-last_nonzero-1)/44100,0.002)

    def test_bundled_cues_are_short_quiet_and_have_smooth_edges(self):
        for name in ('start','stop'):
            with self.subTest(name=name):
                samples=read_sound(name)
                self.assertTrue(0.25<len(samples)/44100<0.50)
                self.assertTrue(0.05<max(map(abs,samples))<0.20)
                self.assertLess(abs(sum(samples)/len(samples)),0.001)
                self.assertLess(max(map(abs,samples[:220])),0.06)
                self.assertLess(max(map(abs,samples[-220:])),0.003)
                self.assertLess(max(abs(b-a) for a,b in zip(samples,samples[1:])),0.04)

    def test_start_ascends_and_stop_descends(self):
        low,high=329.628,493.883
        for name,first,second in (('start',low,high),('stop',high,low)):
            with self.subTest(name=name):
                samples=read_sound(name)
                self.assertGreater(energy(samples,first,0.025,0.075),energy(samples,second,0.025,0.075)*3)
                self.assertGreater(energy(samples,second,0.15,0.20),energy(samples,first,0.15,0.20)*2)

    def test_warm_cues_keep_high_harmonics_subtle(self):
        for name,first in (('start',329.628),('stop',493.883)):
            with self.subTest(name=name):
                samples=read_sound(name)
                fundamental=energy(samples,first,0.03,0.085)
                self.assertGreater(fundamental,10)
                self.assertLess(energy(samples,first*2,0.03,0.085),fundamental*0.10)
                self.assertLess(energy(samples,first*3,0.03,0.085),fundamental*0.03)

    def test_both_cues_are_xcode_resources(self):
        project=(ROOT/'Forblaze.xcodeproj/project.pbxproj').read_text()
        for name in ('start','stop'):
            self.assertIn('Forblaze/Resources/Sounds/recording-'+name+'.wav',project)

if __name__=='__main__':unittest.main()
