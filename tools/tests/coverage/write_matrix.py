"""Render a clearly incomplete checkpoint from measured media facts.

This does not promote import resolution, a boot menu or a preparation marker
to desktop PASS. Hardware bindings must be reviewed against cited documents.
"""
from pathlib import Path
from datetime import date
import argparse
import json
import re

ROOT = Path(__file__).resolve().parents[3]


def cell(text): return str(text).replace('|','/').replace('\n',' ')


def measured_result(sha256, results):
    """Only a reviewed desktop result for the identical input may be PASS."""
    candidates = [item for item in results if item.get('sha256') == sha256]
    for item in reversed(candidates):
        if item.get('result') == 'PASS':
            if item.get('stage') == 'desktop' and item.get('screen') and item.get('evidence'):
                return 'QEMU PASS', 'pulpit', item
        elif item.get('result') in ('FAIL', 'NOT_RUN', 'RUNNER_ERROR', 'INCOMPLETE'):
            labels = {'FAIL':'QEMU FAIL', 'NOT_RUN':'nie uruchomiono', 'RUNNER_ERROR':'błąd adaptera testu', 'INCOMPLETE':'QEMU nieukończono'}
            return labels[item['result']], item.get('stage','—'), item
    return 'oczekuje', '—', {}


def variant_notes(sha256, results):
    """A successful AHCI retry must not hide the same source's NVMe failure."""
    rows = [row for row in results if row.get('sha256') == sha256 and row.get('result') in ('PASS','FAIL','INCOMPLETE')]
    if len(rows) < 2:return ''
    notes = dict.fromkeys(row.get('target','wariant bez opisu dysku')+': '+row['result']+' ('+row.get('stage','—')+')' for row in rows)
    return '; '.join(notes)


def identity(facts):
    source = facts.get('metadata',{})
    install = facts.get('usos',{}).get('install',{})
    legacy = facts.get('usos',{}).get('legacy',{})
    versions = facts.get('binary_versions',{})
    kernel = next((row.get('file_version') for name,row in versions.items() if 'ntoskrnl' in name),None)
    setup = source.get('setup.exe',{}).get('file_version')
    version = kernel or setup
    if install.get('known'):
        version = [install['major'],install['minor'],install['build']]
    version_text = '.'.join(str(n) for n in version) if version else 'nie odczytano wersji binarnej'
    kernel_row = next((row for name,row in versions.items() if 'ntoskrnl' in name),{})
    number = kernel_row.get('nt_build_number',{}).get('build')
    if number and kernel and not install.get('known') and number != kernel[2]:
        version_text = '.'.join(str(n) for n in [kernel[0],kernel[1],number])+' (NtBuildNumber; zasób '+'.'.join(str(n) for n in kernel)+')'
    markers = facts.get('cd_markers',[]) + facts.get('root_markers',[])
    sp = next((re.search(r'(?:\.sp|cdromsp)([0-9])',str(x),re.I).group(1)
               for x in markers if re.search(r'(?:\.sp|cdromsp)([0-9])',str(x),re.I)),None)
    if not sp and install.get('known'):
        sp = {(6,0,6000):'0',(6,0,6001):'1',(6,0,6002):'2',(6,1,7600):'0',(6,1,7601):'1'}.get(tuple(version[:3]))
    if sp is not None: version_text += ' / SP'+sp
    language = facts.get('usos',{}).get('language') or ''
    if not language and legacy.get('locale'):
        lcid = legacy['locale']
        language = {0x0409:'en-US',0x0415:'pl-PL'}.get(lcid,f'LCID 0x{lcid:04x}')
    if not language:
        for name,values in source.items():
            if not isinstance(values,dict):continue
            for key,value in values.items():
                if key.lower().endswith('.localization'): language = value
    arch = install.get('arch') if install.get('known') else legacy.get('arch','unknown')
    if arch in (None,'unknown'):
        machine = next((row.get('machine') for row in versions.values() if row.get('machine')),None)
        arch = {'0x14c':'x86','0x8664':'x64','0x200':'ia64'}.get(machine,arch)
    product = legacy.get('system_id') or facts.get('usos',{}).get('suggested_folder') or 'brak identyfikacji przez sam parser optyczny'
    return version_text,language or 'nie odczytano',arch,product


def main(args):
    inventory = json.loads(args.inventory.read_text(encoding='utf-8'))
    inspected = {row['path']:row for row in json.loads(args.facts.read_text(encoding='utf-8'))}
    catalog = [json.loads(line) for line in args.catalog.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
    folders = {row['directory'].split('\\')[-2].casefold():row for row in catalog}
    results = json.loads(args.results.read_text(encoding='utf-8')) if args.results and args.results.exists() else []
    hardware = json.loads(args.hardware.read_text(encoding='utf-8')) if args.hardware and args.hardware.exists() else {}
    representatives = []
    for result in results:
        digest = result.get('sha256')
        if result.get('candidate') and measured_result(digest,results)[0] == 'QEMU PASS' and hardware.get(digest,{}).get('status') != 'X470 PASS':
            representatives.append('- '+cell(Path(result['path']).name)+': '+result.get('candidate_reason','')+
                ' UEFI → CSMWrap; pusty dysk NVMe lub SATA; sprawdzić start, klawiaturę/mysz i ponowny start. SHA-256 `'+digest+'`.')
    lines = ['# Macierz Windows — checkpoint, testy instalacji nieukończone','',
        f'Data: {date.today().isoformat()}. Baza `97f40f018d1d811dab85c2c1e44f8b6404860189`, po rebase z `1197eb49`.','',
        f"Inwentaryzacja obejmuje {len(inventory['files'])} plików wejściowych. To także archiwa, dyskietki, nośniki aktualizacji i duplikaty — nie liczba unikatowych instalatorów.", '',
        '**Ten dokument nie spełnia jeszcze kryterium pełnych testów QEMU.** Wiersze „oczekuje” nie oznaczają ani PASS, ani wykrytego błędu Windows. Status X470 przypisano wyłącznie tam, gdzie dokumentacja wskazuje dokładne źródło.','',
        '„API” poniżej oznacza uruchomione biblioteczne parsery USOS. W szczególności `windows_legacy_media` nie jest w tej bazie wywoływany przez ekran UEFI; wpis katalogu i profil nie są automatycznym rozpoznaniem wersji/SP starszego ISO. Dla nowszych nośników odczytano także XML WIM.','',
        '| Obraz | Wersja / SP z nośnika | Język / arch | Katalog / profil UEFI | QEMU | Etap | Uwagi / API | X470 |',
        '|---|---|---|---|---|---|---|---|']
    betas = [row for row in inventory['files'] if row['beta']]
    lines.append(f'| Bety: {len(betas)} plików | poza zakresem | — | — | poza zakresem | — | bez testów instalacji i sondowania wersji | nie oceniano |')
    details = []
    for row in inventory['files']:
        if row['beta']:continue
        info = inspected[row['path']]
        facts_list = [info['facts']] if 'facts' in info else [r['facts'] for r in info.get('images',[]) if 'facts' in r]
        facts = facts_list[0] if facts_list else {}
        version,language,arch,product = identity(facts)
        folder = Path(row['path']).parent.name.casefold()
        entry = folders.get(folder)
        route = (entry.get('id','')+' / '+str(entry.get('uefi_profile'))) if entry else 'wymaga przypisania folderu katalogu'
        notes = product
        if entry and entry.get('preparation_block'):notes += '; backend wyłączony: '+entry['preparation_block']
        if row['relative'].lower().endswith(('.7z','.zip')):
            notes += f"; {len(info.get('images',[]))} obrazów wewnątrz archiwum"
        if not facts_list:notes += '; dyskietki/archiwum: parser optyczny nie ma zastosowania'
        status, stage, result = measured_result(row['sha256'], results)
        if result:
            notes += '; '+result.get('reason',result.get('evidence',''))
        variants = variant_notes(row['sha256'],results)
        if variants:notes += '; warianty: '+variants
        hw = hardware.get(row['sha256'],{})
        hw_status = hw.get('status','nie przypisano potwierdzenia dla dokładnego obrazu')
        if hw.get('citations'):
            hw_status += ': '+', '.join('`'+cite+'`' for cite in hw['citations'])
        if hw.get('note'):hw_status += '; '+hw['note']
        lines.append('| '+' | '.join(cell(x) for x in (row['relative'],version,language+' / '+str(arch),route,status,stage,notes,hw_status))+' |')
        details += [f"### `{row['relative']}`",'',f"Magazyn: `{row['root']}`; {row['bytes']} B; SHA-256 `{row['sha256']}`.",'',
            'Źródła metadanych: '+(', '.join('`'+x+'`' for x in facts.get('metadata',{})) or 'brak standardowych małych plików metadanych')+'.','']
        if facts.get('image_versions'):
            details += ['Obrazy instalacyjne WIM: '+', '.join(str(x.get('index'))+': '+str(x.get('name')) for x in facts['image_versions'])+'.','']
        for image in info.get('images',[]):
            details += [f"- `{image['member']}`: {image.get('bytes','?')} B; SHA-256 `{image.get('sha256','nie odczytano')}`."]
        if info.get('images'):details.append('')
    lines += ['', '## Etapy i zakres dowodu','',
        'Etapy: wykrywanie → menu → przygotowanie → micro-Linux → kopiowanie → tekstowy Setup → graficzny Setup → pierwszy start → pulpit. PASS jest zarezerwowany dla pierwszego pulpitu. Zgodność eksportów nie dowodzi ABI ani działania sterownika. QEMU nie zastępuje testu X470.','',
        'Wykonano audyt oryginalnych modułów dla 13 źródeł NT5: XP RTM/SP1 mają brakujące eksporty; badany XP SP2 oraz kontrolne SP3 nie mają braków symboli w badanym zestawie, ale nadal obowiązuje kontrakt pakietu przygotowanego pod SP3. Windows 2000 SP0–SP3 nie mają wymaganych dwóch eksportów USBPORT dla xhci98; kontrolne SP4 mają komplet. Dokładne symbole i opcje napraw znajdą się w raporcie końcowym.','',
        'Pełne dane wejść i wyników: `artifacts/coverage/inventory-second.json`, `media-second.json`, `driver-audit.json`. Surowe bajty Microsoftu nie są elementem tej dokumentacji ani zmian Git.','',
        '## Reprezentanci do X470','',
        'Lista jest uzupełniana po przeglądzie końcowego pulpitu. Pokrewne wersje tej samej rodziny nie uzyskują PASS automatycznie.','',
        *representatives[:8], '',
        '## Inwentaryzacja i SHA-256','']
    lines += details
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text('\n'.join(lines).rstrip()+'\n',encoding='utf-8',newline='\n')
    count = sum(measured_result(row['sha256'],results)[0] == 'QEMU PASS' for row in inventory['files'])
    print('Checkpoint matrix:',len(inventory['files']),'inputs;',count,'reviewed QEMU desktop rows; remaining tests pending')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('inventory','facts','catalog','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--results',type=Path)
    parser.add_argument('--hardware',type=Path)
    main(parser.parse_args())
