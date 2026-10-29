/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Only the measured English Server post-Setup warning, never generic errors. */
static int nt4_minor_warning(const char *s)
{
    const char *a = "One or more minor errors occurred";
    const char *b = "log file";
    int i, j, found_a = 0, found_b = 0;
    for (i = 0; s[i]; i++) {
        for (j = 0; a[j] && s[i+j] == a[j]; j++);
        if (!a[j]) found_a = 1;
        for (j = 0; b[j] && s[i+j] == b[j]; j++);
        if (!b[j]) found_b = 1;
    }
    return found_a && found_b;
}
