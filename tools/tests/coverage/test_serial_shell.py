"""Execute the real quoted collector wrapper through an interactive shell."""
from pathlib import Path
import importlib.util
import os
import subprocess
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
def load(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
shell=load('serial_shell');transport=load('collect_guest_logs')
TMP=ROOT/'artifacts/coverage/serial-shell-host';TMP.mkdir(parents=True,exist_ok=True)


class SerialShell(unittest.TestCase):
    def test_interactive_parent_consumes_script_before_noninteractive_payload(self):
        # Literal shell metacharacters must survive the parent here-document.
        expected=b'literal $USOS_DO_NOT_EXPAND and $(false) and `false`'
        body=("echo COVERAGE_EVIDENCE_BEGIN\n"
              "printf '%s' '"+expected.decode('ascii')+"' | /usr/bin/base64\n"
              "echo COVERAGE_EVIDENCE_END\n")
        with tempfile.TemporaryDirectory(dir=TMP) as temporary:
            env=dict(os.environ,TEMP=temporary,TMP=temporary,ENV='',BASH_ENV='')
            result=subprocess.run([r'C:\Program Files\Git\bin\sh.exe','-i'],
                input=shell.wrap(body).encode('ascii'),capture_output=True,env=env,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
        self.assertEqual(transport.decode_transport(result.stdout.decode('ascii')),expected)
        self.assertEqual(result.stdout.count(b'COVERAGE_EVIDENCE_BEGIN'),1)
        self.assertEqual(result.stdout.count(b'COVERAGE_EVIDENCE_END'),1)

    def test_preserves_quoted_body_normalizes_crlf_and_rejects_ambiguous_input(self):
        script="printf '%s' \"$VALUE\"\r\nexit 0"
        wrapped=shell.wrap(script)
        self.assertIn("printf '%s' \"$VALUE\"\nexit 0\n",wrapped)
        self.assertNotIn('\r',wrapped)
        self.assertEqual(wrapped,shell.wrap(script))
        for invalid in (None,b'exit 0','', ' \n','echo x\0','echo x\rexit 0'):
            with self.assertRaises(ValueError):shell.wrap(invalid)


if __name__=='__main__':unittest.main()
