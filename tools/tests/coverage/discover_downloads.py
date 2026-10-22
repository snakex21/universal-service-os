"""Resolve public archive metadata without saving pages or product-key text."""
from pathlib import Path
from html.parser import HTMLParser
import json
import re
import urllib.parse
import urllib.request

ROOT=Path(__file__).resolve().parents[3]


class Links(HTMLParser):
    def __init__(self):super().__init__();self.links=[]
    def handle_starttag(self,tag,attrs):
        data=dict(attrs)
        if tag=='a' and 'href' in data:self.links.append(data['href'])


def main():
    rows=[]
    ww=[('SP0','413638c2-8d18-c39a-11c3-a4e284a2c3a5'),
        ('SP1','0470c755-f89c-11e7-a755-fa163e9022f0'),
        ('SP2','8ab59004-e827-11e7-a562-fa163e9022f0'),
        ('SP3','ec74f499-e827-11e7-a562-fa163e9022f0')]
    for sp,identifier in ww:
        page='https://winworldpc.com/download/'+identifier
        with urllib.request.urlopen(page,timeout=40) as response:text=response.read().decode()
        parser=Links();parser.feed(text)
        mirror=urllib.parse.urljoin(page,next(x for x in parser.links if '/from/' in x))
        with urllib.request.urlopen(urllib.request.Request(mirror,method='HEAD'),timeout=40) as response:
            original=urllib.parse.unquote(response.url.rsplit('/',1)[-1])
            size=int(response.headers['Content-Length']);url=response.url
        checksum=re.findall(r'Checksum</dt>\s*<dd>\s*<tt[^>]*>([0-9a-fA-F]{32,128})</tt>',text)[0]
        algo={32:'md5',40:'sha1',64:'sha256',128:'sha512'}[len(checksum)]
        rows.append(dict(relative=f'Windows/Windows 2000/Windows 2000 Professional {sp} EN x86.7z',
            original_name=original,identity=f'Windows 2000 Professional {sp}, en-US, x86',
            page=page,url=url,bytes=size,hash_algorithm=algo,published_hash=checksum))
    sources=[
        ('WinXPHomeRTMPolish','Windows/Windows XP/Windows XP Home RTM PL x86.iso','Windows XP Home RTM, pl-PL, x86'),
        ('windows-xp-professional-sp-1-x-09-23842','Windows/Windows XP/Windows XP Professional SP1 EN x86.iso','Windows XP Professional SP1, en-US, x86'),
        ('en_windows_vista_x64_dvd_x12-40712_20240520','Windows/Windows Vista/Windows Vista RTM EN {arch}.iso','Windows Vista RTM multi-edition, en-US'),
        ('vista-sp1','Windows/Windows Vista/Windows Vista Business SP1 EN x86.iso','Windows Vista Business SP1, en-US, x86'),
        ('Windows7HomePremiumRTMx64Polish','Windows/Windows 7/Windows 7 Home Premium RTM PL x64.iso','Windows 7 Home Premium RTM, pl-PL, x64'),
        ('Windows7HomePremiumRTMx86Polish','Windows/Windows 7/Windows 7 Home Premium RTM PL x86.iso','Windows 7 Home Premium RTM, pl-PL, x86'),
    ]
    for identifier,relative,identity in sources:
        with urllib.request.urlopen('https://archive.org/metadata/'+identifier,timeout=40) as response:data=json.load(response)
        for file in data['files']:
            if not file['name'].lower().endswith('.iso'):continue
            arch='x64' if 'x64' in file['name'].lower() else 'x86'
            rows.append(dict(relative=relative.format(arch=arch),original_name=file['name'],
                identity=identity+(' '+arch if '{arch}' in relative else ''),
                page='https://archive.org/details/'+identifier,
                url='https://archive.org/download/'+identifier+'/'+urllib.parse.quote(file['name']),
                bytes=int(file['size']),hash_algorithm='sha1',published_hash=file['sha1']))
    (ROOT/'artifacts/coverage/download-plan.json').write_text(json.dumps(rows,indent=2,ensure_ascii=False),encoding='utf-8')
    report=Path(r'C:\Users\ASRock\Documents\Codex\zadania\2026-10-22-macierz-windows-RAPORT.md')
    if report.exists():raise FileExistsError('initial download plan must not replace an existing report')
    lines=['# Macierz Windows — raport roboczy','',
        'Data rozpoczęcia: 2026-10-20. Baza: 1197eb4981ca1dd7389cfea96ae072c24d3ef812.',
        'Gałąź: codex/macierz-windows. Poprzednie zadanie review4-i-64mb zakończone.','',
        '## Lista do pobrania','',
        'Lista zapisana przed transferem. Rozmiary archiwów / ISO według źródeł. Starsze SP sprawdzają zgodność pakietów; inne języki i architektury rozdzielają routing.','',
        '| Wersja / edycja / język / arch | Źródło | GiB | Powód |','|---|---|---:|---|']
    for row in rows:
        lines.append(f"| {row['identity']} | [{row['original_name']}]({row['page']}) | {row['bytes']/1024**3:.2f} | Brak tej kombinacji w bibliotece OS; porównanie wersji/SP/architektury. |")
    lines += ['',f"Plan Windows: {len(rows)} plików; {sum(r['bytes'] for r in rows)/1024**3:.2f} GiB.",
        'Pominięto ponowne pobieranie XP SP2/SP3, Visty SP2 i Windows 7 SP1 — są lokalnie.',
        'WinISO.pl: strony opisów działają, ale link.winiso.pl zwraca HTTP 403 w kliencie pobierającym; wybrano inne archiwa wskazane przez użytkownika.',
        'MacOS będzie osobnym zasobem do przyszłych testów; nie wchodzi do macierzy Windows.','',
        '## Stan pracy','','Inwentaryzacja, audyt mediów i przebiegi QEMU w toku; to nie jest raport końcowy.','']
    report.write_text('\n'.join(lines),encoding='utf-8')
    print('Plan saved before download:',len(rows),'files',round(sum(r['bytes'] for r in rows)/1024**3,2),'GiB')


if __name__=='__main__':main()
