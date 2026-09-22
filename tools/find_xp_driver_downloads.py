import urllib.request, json, re
from pathlib import Path
out = Path(__file__).resolve().parents[1] / 'artifacts/xp-drivers/research'
out.mkdir(parents=True, exist_ok=True)
urls = {
 'zone': 'https://zone94.com/software/operating-systems/123-windows-xp-professional-sp3-x86-integral-edition',
 'genahci': 'https://api.github.com/repos/GeorgeK1ng/GenAHCI/releases',
 'xhci98': 'https://api.github.com/repos/yeokm1/xhci98/releases',
 'george-repos': 'https://api.github.com/users/GeorgeK1ng/repos?per_page=100',
}
for name, url in urls.items():
 try:
  data=urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'USOS-driver-review'}),timeout=30).read()
  (out/(name+'.txt')).write_bytes(data)
  print(name, len(data))
  if name=='zone':
   for href in re.findall(r'href=[\"\x27]([^\"\x27]+)',data.decode(errors='replace')):
    if any(s in href.lower() for s in ['upload','patch','download','mediafire']): print(href)
  elif name=='george-repos': print([x['name'] for x in json.loads(data)])
  else:
   for release in json.loads(data)[:3]: print(release['tag_name'],[(a['name'],a['browser_download_url'],a['size']) for a in release['assets']])
 except Exception as e: print(name,str(e))
