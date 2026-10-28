"""A stale settings reader must not survive rebasing a private fixture."""
from pathlib import Path
import importlib.util
import unittest

spec=importlib.util.spec_from_file_location('sync_nt5',Path(__file__).with_name('synchronize_nt5.py'))
sync=importlib.util.module_from_spec(spec);spec.loader.exec_module(sync)


class SynchronizationTests(unittest.TestCase):
    def test_current_base_and_unchanged_source_bound_payloads(self):
        entry=lambda data:sync.cpio.Entry('example',0o100644,data)
        parser='usr/lib/usos/xp_user_settings.sh'
        driver='usr/lib/usos/xp-drivers/hash/driver.sys'
        base={parser:entry(b'current parser'), 'bin/tool':entry(b'current tool')}
        old={parser:entry(b'stale parser'), 'bin/tool':entry(b'stale tool'),
             driver:entry(b'opaque synthetic bytes'),
             **{name:entry(b'unchanged helper') for name in sync.ENTRIES}}
        result=sync.combine(base,old)
        self.assertIs(result[parser],base[parser])
        self.assertIs(result['bin/tool'],base['bin/tool'])
        self.assertIs(result[driver],old[driver])
        self.assertFalse(sync.package_entry('usr/lib/usos/xp-drivers-not-a-package'))

    def test_incomplete_inputs_are_rejected(self):
        with self.assertRaises(ValueError):sync.combine({}, {})
        with self.assertRaises(ValueError):sync.combine({'usr/lib/usos/xp_user_settings.sh':None}, {})


if __name__=='__main__':unittest.main()
