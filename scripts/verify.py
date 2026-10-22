#!/usr/bin/env python3
from pathlib import Path
import subprocess
import re
import sys
ROOT=Path(__file__).resolve().parent.parent
class VerificationError(RuntimeError): pass
def test_command(suite,filter=''):
    names={'core':'ForblazeCoreTests','application':'ForblazeApplicationTests','macos':'ForblazeMacOSTests'}
    if suite in names:
        return ['swift','test','--package-path',str(ROOT/'Packages/ForblazeKit'),'--filter',names[suite]+(r'\.'+filter if filter else '')]
    if suite=='app':
        command=build_command('test')
        if filter: command+=['-only-testing:ForblazeTests/'+filter]
        return command
    raise VerificationError('不明なsuite: '+suite)
def build_command(action='build'):
    return ['xcodebuild','-project',str(ROOT/'Forblaze.xcodeproj'),'-scheme','Forblaze','-derivedDataPath',str(ROOT/'build/DerivedData'),'-destination','platform=macOS,arch=arm64',action,'CODE_SIGNING_ALLOWED=NO']
def run_tests(command):
    result=subprocess.run(command,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    print(result.stdout[-12000:],end='')
    if result.returncode: raise VerificationError('テストコマンド失敗')
    counts=re.findall(r'Test run with (\d+) tests? .*passed',result.stdout)
    count=sum(map(int,counts))
    if count==0: raise VerificationError('一致するテストが0件、または結果を確認できない')
    return count
def main():
    mode=sys.argv[1]
    if mode in ('build','test','test-one'):
        subprocess.run([sys.executable,str(ROOT/'scripts/generate-project.py')],check=True)
    if mode=='build': subprocess.run(build_command(),cwd=ROOT,check=True)
    elif mode=='test-one': run_tests(test_command(sys.argv[2],sys.argv[3]))
    elif mode=='test':
        subprocess.run([sys.executable,'-m','unittest','discover','-s','scripts','-p','test_*.py'],cwd=ROOT,check=True)
        run_tests(['swift','test','--package-path',str(ROOT/'Packages/ForblazeKit')])
        run_tests(test_command('app'))
if __name__=='__main__':
    try: main()
    except (VerificationError,subprocess.CalledProcessError) as error:
        print(str(error),file=sys.stderr); sys.exit(1)
