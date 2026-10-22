"""Execute actual backend IRQ bodies against canonical 82576 MMIO registers."""
from pathlib import Path
import os,re,shutil,subprocess,tempfile,unittest

ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'tools/nt/usosnet/src'

class ActualBackend(unittest.TestCase):
    def test_canonical_enable_claim_mask_and_shared_line(self):
        source=(SRC/'usosnet_igb.c').read_text()
        names={'STATUS','ICR','IMS','IMC','IAM','EIMC','EIMC_ALL','ICR_LSC','ICR_RXSEQ',
               'ICR_RXDMT0','ICR_RXO','ICR_RXT0','ICR_ASSERTED','IMS_MASK'}
        definitions='\n'.join(line for line in source.splitlines() if
            (m:=re.match(r'#define\s+(\w+)\s+',line)) and m[1] in names)
        body=source[source.index('static void IgbIrqDisable('):source.index('static NDIS_STATUS IgbReset(')]
        code=r'''
#include <stdint.h>
#include <assert.h>
#include <stdio.h>
#define TRUE 1
#define FALSE 0
typedef uint32_t ULONG;
typedef struct { int IrqMasked; } ADAPTER,*PADAPTER;
static uint32_t regs[0x2000/4],reads,writes,last_read,last_write;
static void wr(PADAPTER a,uint32_t at,uint32_t v) {
    (void)a; writes++;last_write=at;
    if(at==0xd0)regs[0xd0/4]|=v;
    else if(at==0xd8)regs[0xd0/4]&=~v;
    else if(at==0x1528)regs[0x1524/4]&=~v;
    else assert(!"Unexpected IRQ MMIO write");
}
static uint32_t rd(PADAPTER a,uint32_t at) {
    uint32_t v;(void)a;reads++;last_read=at;
    assert(at==8 || at==0xc0);v=regs[at/4];
    if(at==0xc0)regs[at/4]=0;return v;
}
#define WR32(a,r,v) wr(a,r,v)
#define RD32(a,r) rd(a,r)
'''+definitions+'\n#include "usosnet_irq.h"\n'+body+r'''
int main(void) {
    ADAPTER a={1};uint32_t n;
    assert(ICR==0xc0 && IMS==0xd0 && IMC==0xd8 && IAM==0xe0);
    assert(IgbIrqRead(&a)==0 && reads==0);
    IgbIrqEnable(&a);assert(!a.IrqMasked && writes==1 && last_write==0xd0);
    assert(regs[0xd0/4]==0xdc); /* LSC/RXSEQ/RXDMT/RXO/RX timer */
    regs[0xc0/4]=0x80;n=writes;
    assert(IgbIrqRead(&a)==0 && !a.IrqMasked && writes==n && last_read==0xc0);
    regs[0xc0/4]=0x80000080;regs[0x1524/4]=0xffffffff;
    assert(IgbIrqRead(&a)==0x80000080 && a.IrqMasked);
    assert(regs[0xd0/4]==0 && regs[0x1524/4]==0 && last_read==8);
    n=reads;assert(IgbIrqRead(&a)==0 && reads==n);
    IgbIrqEnable(&a);regs[0xc0/4]=0xffffffff;n=writes;
    assert(IgbIrqRead(&a)==0 && writes==n && !a.IrqMasked);
    puts("Actual IRQ backend canonical MMIO, claim, shared-line and mask PASS");
    return 0;
}
'''
        scratch=ROOT/'artifacts/igb-irq-register-test';scratch.mkdir(parents=True,exist_ok=True)
        cc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        with tempfile.TemporaryDirectory(dir=scratch) as work:
            work=Path(work);c=work/'probe.c';exe=work/'probe.exe';c.write_text(code)
            env=dict(os.environ,TEMP=str(work),TMP=str(work))
            built=subprocess.run([cc,'-std=c99','-Wall','-Werror','-Wno-misleading-indentation','-I',str(SRC),str(c),'-o',str(exe)],env=env,capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stderr)
            ran=subprocess.run([str(exe)],env=env,capture_output=True,text=True)
            self.assertEqual(ran.returncode,0,ran.stderr)
            self.assertIn('canonical MMIO',ran.stdout)

if __name__=='__main__':unittest.main()
