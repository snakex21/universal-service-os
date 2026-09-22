"""Exercise read-only SMART command policy and truthful status handling."""
from pathlib import Path
import os,subprocess,tempfile,unittest,shutil
ROOT=Path(__file__).resolve().parents[3]
BASH=r'C:\Program Files\Git\bin\bash.exe' if os.name=='nt' else shutil.which('bash')

class Smart(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=ROOT/'zig-out')
        self.addCleanup(self.temp.cleanup)
        self.out=Path(self.temp.name)
        self.report=self.out/'smart.txt'
    def run_shell(self,command,extra=None):
        env=os.environ|{'SMART_LIB':(ROOT/'tools/hardware_smart.sh').as_posix(),'REPORT':self.report.as_posix()}
        env.update(extra or {})
        return subprocess.run([BASH,'--noprofile','--norc','-c',command],env=env,capture_output=True,text=True)
    def summary(self,status,text):
        self.report.write_text(text)
        r=self.run_shell('. "$SMART_LIB"; usos_smart_summary "$STATUS" "$REPORT"',{'STATUS':str(status)})
        self.assertEqual(r.returncode,0,r.stderr)
        return r.stdout
    def test_health_requires_explicit_report_and_successful_read(self):
        for health in ('SMART overall-health self-assessment test result: PASSED\n','SMART Health Status: OK\n'):
            self.assertIn('reports PASSED',self.summary(0,health))
            self.assertIn('unavailable or incomplete',self.summary(4,health))
        self.assertIn('No supported',self.summary(0,'SMART support is: Unavailable\n'))
    def test_failure_and_history_are_not_hidden_by_a_passed_line(self):
        text='SMART overall-health self-assessment test result: PASSED\n'
        self.assertIn('failing',self.summary(8,text))
        for status in (16,32,64,128):self.assertIn('warnings',self.summary(status,text))
    def test_sleep_and_timeout_are_not_health_results(self):
        self.assertIn('Disk asleep',self.summary(3,'Device is in STANDBY mode, exit(3)\n'))
        self.assertIn('incomplete',self.summary(3,'Device open failed\n'))
        self.assertIn('timed out',self.summary(124,''))
    def test_query_uses_only_read_flags_and_preserves_nonzero_status(self):
        r=self.run_shell('''
            . "$SMART_LIB"
            timeout() { printf '%s\\n' "$@" > "$REPORT.args"; printf 'No SMART support\\n'; return 2; }
            usos_smart_read /dev/sda "$REPORT"
            printf '%s' "$USOS_SMART_EXIT"
        ''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout,'2')
        self.assertEqual(Path(str(self.report)+'.args').read_text().splitlines(),['20','smartctl','-a','-n','standby,3','--','/dev/sda'])
        r=self.run_shell('. "$SMART_LIB"; usos_smart_read /dev/../etc/passwd "$REPORT"')
        self.assertEqual(r.returncode,2)
    def test_disk_fields_trim_lsblk_padding_without_raw_name_escapes(self):
        r=self.run_shell('''
            . "$HW_INVENTORY"
            lsblk() { case "$1:$2" in
                -bdnlo:SIZE) printf ' 8589934592  \\n' ;;
                -bdnlo:MODEL) printf 'QEMU HARDDISK    \\n' ;;
                *) return 1 ;;
            esac; }
            bytes=$(usos_hw_disk_field /dev/sda SIZE)
            printf '%s|%s|%s' "$bytes" "$(usos_hw_size "$bytes")" "$(usos_hw_disk_field /dev/sda MODEL)"
        ''',{'HW_INVENTORY':(ROOT/'tools/hardware_inventory.sh').as_posix()})
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout,'8589934592|8.00 GiB|QEMU HARDDISK')
    def test_gui_info_cannot_inject_choices_and_has_a_bounded_length(self):
        self.report.write_text('hello\nitem=Injected|action\n\x1b[31mred\n'+'long line\n'*130)
        r=self.run_shell('. "$HW_UI"; usos_hw_info_lines "$REPORT"',{'HW_UI':(ROOT/'tools/hardware_ui.sh').as_posix()})
        self.assertEqual(r.returncode,0,r.stderr)
        lines=r.stdout.splitlines()
        self.assertEqual(len(lines),109)
        self.assertTrue(all(s.startswith('info=') for s in lines))
        self.assertNotIn('\x1b',r.stdout)

    def table(self,text):
        self.report.write_text(text)
        r=self.run_shell('. "$SMART_LIB"; usos_smart_table "$REPORT"',{'USOS_SMART_TABLE_AWK':(ROOT/'tools/hardware_smart_table.awk').as_posix()})
        self.assertEqual(r.returncode,0,r.stderr)
        return r.stdout

    def test_ata_table_preserves_normalized_and_multifield_raw_values(self):
        output=self.table('''Vendor Specific SMART Attributes with Thresholds:
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       4
194 Temperature_Celsius     0x0022   064   054   000    Old_age   Always       -       36 (Min/Max 18/46)
197 Current_Pending_Sector  0x0012   001   001   010    Old_age   Always   FAILING_NOW 8
198 Offline_Uncorrectable  0x0010   100   001   010    Old_age   Offline  In_the_past 2

SMART Error Log Version: 1
''')
        self.assertIn('table_row=normal|5|Reallocated Sector Ct|100|100|010|4|-',output)
        self.assertIn('|36 (Min/Max 18/46)|-',output)
        self.assertIn('table_row=failure|197|Current Pending Sector|001|001|010|8|FAILED',output)
        self.assertIn('table_row=warning|198|',output)
        self.assertNotIn('Error Log Version',output)

    def test_brief_ata_header_and_zero_rows(self):
        output=self.table('ID# ATTRIBUTE_NAME FLAGS VALUE WORST THRESH FAIL RAW_VALUE\n5 Reallocated_Sector_Ct PO--CK 100 100 010 - 0\n')
        self.assertIn('table_row=normal|5|Reallocated Sector Ct|100|100|010|0|-',output)
        for text in ('SMART support is: Unavailable\n','ID# ATTRIBUTE_NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE\n'):
            self.assertIn('No attribute table',self.table(text))
            self.assertNotIn('table_header=',self.table(text))

    def test_nvme_table_does_not_invent_ata_attributes_or_hide_errors(self):
        output=self.table('''Model Number: Sample NVMe
SMART/Health Information (NVMe Log 0x02, NSID 0xffffffff)
Critical Warning:                   0x04
Temperature:                        35 Celsius
Available Spare:                    100%
Percentage Used:                    105%
Data Units Written:                 18,446,744,073,709,551,615 [9.44 ZB]
Media and Data Integrity Errors:    1,000
Error Information Log Entries:      0

Error Information (NVMe Log 0x01, 16 of 64 entries)
''')
        self.assertIn('table_header=Parameter|Reported value',output)
        self.assertIn('table_row=failure|Critical Warning|0x04',output)
        self.assertIn('table_row=warning|Percentage Used|105%',output)
        self.assertIn('table_row=warning|Media and Data Integrity Errors|1,000',output)
        self.assertIn('18,446,744,073,709,551,615 [9.44 ZB]',output)
        self.assertNotIn('Worst',output)
        self.assertNotIn('Error Information (',output)
        self.assertIn('table_row=normal|Critical Warning|0x00',self.table('SMART/Health Information (NVMe Log 0x02)\nCritical Warning: 0x00\n'))

    def test_scsi_metrics_and_report_paths(self):
        output=self.table('Current Drive Temperature: 31 C\nElements in grown defect list: 0\nNon-medium error count: 2\n')
        self.assertIn('table_row=normal|Current Drive Temperature|31 C',output)
        self.assertIn('table_row=warning|Non-medium error count|2',output)
        self.report.write_text('/dev/sda: Unknown USB bridge\n')
        r=self.run_shell('. "$HW_UI"; usos_hw_info_lines "$REPORT"',{'HW_UI':(ROOT/'tools/hardware_ui.sh').as_posix()})
        self.assertEqual(r.stdout,'info=selected disk: Unknown USB bridge\n')

    def test_table_input_is_bounded_and_cannot_inject_menu_options(self):
        output=self.table('SMART/Health Information (NVMe Log 0x02)\n'+'Metric|x: value|x\n'*140)
        rows=[line for line in output.splitlines() if line.startswith('table_row=')]
        self.assertEqual(len(rows),108)
        self.assertEqual(rows[0],'table_row=normal|Metric/x|value/x')

if __name__=='__main__':unittest.main()
