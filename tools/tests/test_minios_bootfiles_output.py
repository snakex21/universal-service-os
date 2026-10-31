# SPDX-License-Identifier: GPL-3.0-or-later
import json
from pathlib import Path

import pytest
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import bootfiles_output as limits


def test_limits_fit_exact_approval():
    assert sum(limits.LIMITS.values()) <= 208 * limits.MIB


def test_prewrite_limit_and_extra_file(tmp_path):
    scope = limits.Scope(tmp_path)
    with pytest.raises(ValueError):
        scope.save('entropy.bin', b'x'*65)
    assert (tmp_path/'entropy.bin').stat().st_size == 0
    (tmp_path/'other').write_bytes(b'x')
    with pytest.raises(ValueError):
        scope.audit()


def test_json_limit_and_audit(tmp_path):
    scope = limits.Scope(tmp_path)
    scope.save_json('result.json', {'passed': False})
    assert json.loads((tmp_path/'result.json').read_text()) == {'passed': False}
    assert scope.audit() == (tmp_path/'result.json').stat().st_size
