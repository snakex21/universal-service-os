/* Exercise the production configuration parser with real text fixtures.
 * Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdio.h>
#include "config.h"
int main(int argc, char **argv)
{
    FILE *f;
    char line[160];
    net_config c;
    if (argc != 2 || !(f=fopen(argv[1],"rb"))) return 2;
    net_config_begin(&c);
    while (fgets(line,sizeof(line),f)) net_config_line(&c,line);
    fclose(f);
    printf("valid=%d ip=%08lx mask=%08lx gateway=%08lx dns=%08lx\n",
           net_config_valid(&c),(unsigned long)c.ip,(unsigned long)c.mask,
           (unsigned long)c.gateway,(unsigned long)c.dns);
    return 0;
}
