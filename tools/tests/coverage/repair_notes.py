"""Recover own Polish assessment notes accidentally read as Windows CP1250.

Only human assessment fields are eligible. Media paths, hashes, versions,
result codes and evidence identities are never rewritten. Always UTF-8 I/O.
"""
from pathlib import Path
import argparse
import json

FIELDS={'reason','note','stage','target','candidate_reason'}


def repair(text):
    for _ in range(6):
        result=[];at=0
        while at<len(text):
            try:lead=text[at].encode('cp1250')[0]
            except UnicodeEncodeError:lead=0
            length=2 if lead in (0xc2,0xc3,0xc4,0xc5) else 3 if lead==0xe2 else 4 if lead==0xf0 else 0
            if length and at+length<=len(text):
                try:
                    data=text[at:at+length].encode('cp1250')
                    if len(data)==length and all(0x80<=n<=0xbf for n in data[1:]):
                        result.append(data.decode('utf-8'));at+=length;continue
                except (UnicodeEncodeError,UnicodeDecodeError):pass
            result.append(text[at]);at+=1
        updated=''.join(result)
        if updated==text:return text
        text=updated
    return text


def main(path):
    rows=json.loads(path.read_text(encoding='utf-8'));changes=0
    for row in rows:
        for key in FIELDS & row.keys():
            value=row[key]
            if isinstance(value,str):
                fixed=repair(value)
                if fixed!=value:row[key]=fixed;changes+=1
    if changes:path.write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Own human fields repaired:',changes)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('path',type=Path)
    main(parser.parse_args().path)
