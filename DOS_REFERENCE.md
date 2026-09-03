# MS-DOS reference source

Universal Service OS uses the public Microsoft MS-DOS source tree as a behavioural reference for DOS compatibility.

Reference repository:
- local checkout: `third_party/msdos-reference`
- upstream clone URL: `https://github.com/microsoft/MS-DOS.git`
- upstream web URL: `https://github.com/microsoft/MS-DOS`
- exact reference commit: `2d04cacc5322951f187bb17e017c12920ac8ebe2`
- immutable tree URL: `https://github.com/microsoft/MS-DOS/tree/2d04cacc5322951f187bb17e017c12920ac8ebe2`
- upstream license: MIT

Initial compatibility work is based primarily on MS-DOS 4.0 at that exact commit:
- `v4.0/src/INC/EXE.INC` - EXEC argument structures and MZ/EXE header layout,
- `v4.0/src/INC/PDB.INC` - Process Data Block / PSP layout,
- `v4.0/src/DOS/EXEC.ASM` - COM and EXE loading, initial register state, memory requirements and relocation behaviour,
- `v4.0/src/DOS/DISP.ASM` and `v4.0/src/DOS/MS_TABLE.ASM` - INT 21h dispatch behaviour for DOS API compatibility.

Immutable source URLs:
- `https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/v4.0/src/INC/EXE.INC`
- `https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/v4.0/src/INC/PDB.INC`
- `https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/v4.0/src/DOS/EXEC.ASM`
- `https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/v4.0/src/DOS/DISP.ASM`
- `https://github.com/microsoft/MS-DOS/blob/2d04cacc5322951f187bb17e017c12920ac8ebe2/v4.0/src/DOS/MS_TABLE.ASM`

The Microsoft tree is reference material and is excluded from the USOS repository by `.gitignore`. A clean clone can reproduce the exact reference checkout with the repository URL and commit above.

No execution architecture is implied by these reference files. The COM/MZ loader, PSP/PDB structures, relocation logic and INT 21h semantics can be reused for either native real-mode execution or an emulated environment. The execution strategy must be chosen separately.
