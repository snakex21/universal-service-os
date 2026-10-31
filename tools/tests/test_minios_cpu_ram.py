"""CPU-audit and RAM search decisions only; never launches a guest."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parents[1] / "minios"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controller = load("cpu_search_unit", "cpu_ram_case.py")
isa = load("cpu_isa_unit", "audit_ia32.py")


class CpuRam(unittest.TestCase):
    def search(self, passing, minimum):
        suite = controller.Suite.__new__(controller.Suite)
        attempts = []
        def trial(arch, cpu, memory):
            attempts.append(memory)
            return {"application_pass": memory >= minimum}
        suite.trial = trial
        result = suite.minimum("ia32", "qemu32", passing)
        return result, attempts

    def test_firmware_search_proves_adjacent_lower_failure(self):
        result, attempts = self.search(64, 52)
        self.assertEqual(result, (52, 51))
        self.assertEqual(len(attempts), len(set(attempts)))
        self.assertIn(52, attempts); self.assertIn(51, attempts)

    def test_bios_search_crosses_small_sizes_without_repeating_installs(self):
        result, attempts = self.search(32, 2)
        self.assertEqual(result, (2, 1))
        self.assertEqual(attempts, [16, 8, 4, 2, 1])

    def test_i486_audit_rejects_simd_cmov_and_new_clock_instructions(self):
        for text in ("\tmovaps %xmm0, %xmm1\n", "\tcmovne %eax, %ebx\n", "\trdtsc \n"):
            with self.subTest(text=text), self.assertRaises(ValueError): isa.audit(text)
        isa.audit("\tpush %ebp\n\tmov %esp, %ebp\n\tbswap %eax\n\tret\n")


if __name__ == "__main__": unittest.main()
