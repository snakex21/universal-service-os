"""Deterministic emitted-assembly audit fixtures; no compiler or CPU probing."""
# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("tsc_isa", Path(__file__).resolve().parents[1] / "minios" / "audit_ia32.py")
isa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(isa)

INTEL = """
L_tsc_clock.readGuarded:
    push ebx
    #APP
    # USOS_TSC_GUARD_BEGIN readGuarded
    xor ecx, ecx
    test bl, bl
    je Ltmp127
    rdtsc
    mov ecx, 1
Ltmp127:
    # USOS_TSC_GUARD_END readGuarded
    #NO_APP
    pop ebx
    ret
"""
ATT = """
tsc_clock.readGuarded:
    # USOS_TSC_GUARD_BEGIN readGuarded
    xorl %ecx, %ecx
    testb %bl, %bl
    jz .Ltmp7
    rdtsc
    movl $1, %ecx
.Ltmp7:
    # USOS_TSC_GUARD_END readGuarded
    ret
"""


class GuardedTscAudit(unittest.TestCase):
    def refuse(self, text):
        with self.assertRaises(ValueError):
            isa.audit(text)

    def test_ordinary_i486_is_still_accepted(self):
        isa.audit("push %ebp\nmov %esp,%ebp\nbswap %eax\nret\n")

    def test_exact_local_guards_in_both_assembly_dialects(self):
        isa.audit(INTEL)
        isa.audit(ATT)
        elf=INTEL.replace('L_tsc_clock.readGuarded:', '.Ltsc_clock.readGuarded:').replace('Ltmp127','.Ltmp127')
        isa.audit(elf)
        self.refuse(elf.replace('.Ltsc_clock.readGuarded:', '.Lforeign.readGuarded:'))

    def test_all_old_global_restrictions_remain_in_force(self):
        for instruction in ("movaps xmm0,xmm1", "cmovne eax,ebx", "cmpxchg8b [eax]", "rdtscp", "vzeroupper"):
            with self.subTest(instruction=instruction):
                self.refuse(INTEL + "\n" + instruction + "\n")

    def test_markerless_and_foreign_function_rdtsc_is_forbidden(self):
        self.refuse("rdtsc\n")
        self.refuse(INTEL.replace("L_tsc_clock.readGuarded:", "L_unrelated.readGuarded:"))
        self.refuse(INTEL.replace("# USOS_TSC_GUARD_BEGIN", "USOS_TSC_GUARD_BEGIN"))
        self.refuse(INTEL.replace("# USOS_TSC_GUARD_END", "USOS_TSC_GUARD_END"))

    def test_capability_test_and_zero_skip_are_both_mandatory(self):
        for before, after in (("test bl, bl", "test al, al"), ("je Ltmp127", "jne Ltmp127"), ("je Ltmp127", "jmp Ltmp127"), ("Ltmp127:", "Ltmp128:"), ("xor ecx, ecx", "xor eax, eax"), ("mov ecx, 1", "mov ecx, 0")):
            with self.subTest(after=after):
                self.refuse(INTEL.replace(before, after))

    def test_branch_cannot_land_before_instruction(self):
        text = INTEL.replace("    rdtsc\n", "Ltmp127:\n    rdtsc\n").replace("Ltmp127:\n    # USOS_TSC_GUARD_END", "    # USOS_TSC_GUARD_END")
        self.refuse(text)

    def test_additional_instructions_calls_and_alternative_encodings_are_not_allowed(self):
        for insertion in ("    nop\n", "    jmp Ltmp127\n", "    call other\n", "    .byte 15,49\n"):
            with self.subTest(insertion=insertion):
                self.refuse(INTEL.replace("    rdtsc\n", insertion + "    rdtsc\n"))
        self.refuse(INTEL.replace("    rdtsc", "    rep rdtsc"))

    def test_duplicates_missing_markers_and_outside_instructions_are_rejected(self):
        self.refuse(INTEL + INTEL)
        self.refuse(INTEL + "\nrdtsc\n")
        self.refuse(INTEL.replace("# USOS_TSC_GUARD_BEGIN readGuarded", "# absent"))
        self.refuse(INTEL.replace("# USOS_TSC_GUARD_END readGuarded", "# absent"))


if __name__ == "__main__":
    unittest.main()
