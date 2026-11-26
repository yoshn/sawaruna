"""Build the MSIX layout folder: python3 make_layout.py <Sawaruna.exe> <out_dir> <version x.y.z> [--test]
--test adds install-test.ps1 for a Developer Mode test install (never in the Store package)."""
import json, os, shutil, sys
here = os.path.dirname(os.path.abspath(__file__))
exe, out, ver = sys.argv[1], sys.argv[2], sys.argv[3]
parts = (ver.split('.') + ['0', '0', '0'])[:3]
version = '.'.join(parts) + '.0'   # Store requires the 4th number to be 0
cfg = json.load(open(os.path.join(here, 'store.json'), encoding='utf-8'))
os.makedirs(out, exist_ok=True)
shutil.copytree(os.path.join(here, 'Assets'), os.path.join(out, 'Assets'), dirs_exist_ok=True)
shutil.copy(exe, os.path.join(out, 'Sawaruna.exe'))
m = open(os.path.join(here, 'AppxManifest.xml'), encoding='utf-8').read()
for k, v in {'@IDENTITY_NAME@': cfg['identity_name'], '@PUBLISHER@': cfg['publisher'],
             '@PUBLISHER_DISPLAY_NAME@': cfg['publisher_display_name'], '@VERSION@': version}.items():
    m = m.replace(k, v)
assert '@' not in m, 'unfilled placeholder'
open(os.path.join(out, 'AppxManifest.xml'), 'w', encoding='utf-8').write(m)
if '--test' in sys.argv[4:]:
    shutil.copy(os.path.join(here, 'install-test.ps1'), os.path.join(out, 'install-test.ps1'))
print('layout ready:', out, version)
