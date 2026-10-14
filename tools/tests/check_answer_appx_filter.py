"""The rendered Remove-AppxProvisionedPackage commands, run through CreateProcess with the
two cmdlets replaced by a fixed package list and an echo: proves the quoting and the filter
(nothing is removed).

    python tools/tests/check_answer_appx_filter.py src/flow/answer/testdata/golden/options.windows-11.amd64.xml
"""
import subprocess
import sys
import xml.etree.ElementTree as ET

NS = '{urn:schemas-microsoft-com:unattend}'
names = ['Microsoft.BingNews', 'Microsoft.WindowsCalculator', 'Microsoft.WindowsStore', 'Microsoft.XboxGamingOverlay',
         'Microsoft.People', 'Microsoft.Windows.PeopleExperienceHost', 'MSTeams', 'Microsoft.WindowsNotepad',
         'Microsoft.Paint', 'Microsoft.MSPaint', 'Microsoft.OutlookForWindows', 'Microsoft.Windows.Photos']
fake = '@(' + ','.join("[pscustomobject]@{DisplayName='%s'}" % n for n in names) + ')'
removed = []
for p in ET.parse(sys.argv[1]).getroot().iter(NS + 'Path'):
    c = p.text
    if 'Remove-AppxProvisionedPackage' not in c:
        continue
    c = c.replace('Get-AppxProvisionedPackage -Online', fake).replace('Remove-AppxProvisionedPackage -Online', 'ForEach-Object {$_.DisplayName}')
    r = subprocess.run(c, capture_output=True, text=True)
    if r.returncode:
        print('FAIL', r.stderr)
    removed += r.stdout.split()
print('removed:', sorted(removed))
keep = {'Microsoft.WindowsCalculator', 'Microsoft.WindowsStore', 'Microsoft.Windows.PeopleExperienceHost', 'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.Windows.Photos'}
bad = keep & set(removed)
want = set(names) - keep
print('RESULT', 'PASS' if not bad and set(removed) == want else f'FAIL bad={bad} missing={want - set(removed)}')
