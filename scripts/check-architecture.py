#!/usr/bin/env python3
from pathlib import Path
import json
import re
import subprocess
EXPECTED={'ForblazeCore':[], 'ForblazeApplication':['ForblazeCore'], 'ForblazeMacOS':['ForblazeApplication','ForblazeCore']}
FORBIDDEN={'AppKit','SwiftUI','Observation','Speech','AVFoundation','ApplicationServices','CoreGraphics','ForblazeMacOS'}
def validate_graph(graph):
    for name,deps in EXPECTED.items():
        if set(graph.get(name,[]))!=set(deps):raise ValueError('依存方向違反: '+name)
def imports(text):
    return re.findall(r'\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?(\w+)',text)
def validate_imports(root):
    paths=[(root/'Packages/ForblazeKit/Sources'/name,FORBIDDEN|({'ForblazeApplication'} if name=='ForblazeCore' else set())) for name in ('ForblazeCore','ForblazeApplication')]
    paths += [(root/'Forblaze'/name,{'ForblazeMacOS'}) for name in ('Features','Presentation')]
    paths += [(root/'Packages/ForblazeKit/Sources/ForblazeMacOS',{'Forblaze'})]
    for folder,denied in paths:
        for p in folder.rglob('*.swift'):
            found=set(imports(p.read_text()))&denied
            if found:raise ValueError(str(p)+': '+','.join(sorted(found)))
def main():
    root=Path(__file__).resolve().parent.parent
    package=json.loads(subprocess.check_output(['swift','package','--package-path',str(root/'Packages/ForblazeKit'),'dump-package'],text=True))
    graph={t['name']:[next(iter(d.values()))[0] for d in t['dependencies']] for t in package['targets']}
    validate_graph(graph);validate_imports(root)
    if package['swiftLanguageVersions']!=['6']:raise ValueError('Swift 6が必要')
    print('依存方向とSwift 6の検査に成功')
if __name__=='__main__':main()
