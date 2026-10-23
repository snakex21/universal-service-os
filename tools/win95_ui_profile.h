static const Page pages[] = {
    /* Original OSR1 EN initial welcome: this short wizard puts its active
     * Next at y339..360, outside the later page's y395 button probe.
     * Match both the title and the static To begin, click Next paragraph. */
    {"welcome-en", UINT64_C(0x7a49b78a53a896db), UINT64_C(0xcad563218326ccda), 214, 140, 360, 25},
    /* Original OSR1 EN OEM 950. Static heading and labels only: the
     * Product Identification edit at x214..463,y211..234 is excluded.
     * Its Next button is disabled while the field is empty. */
    {"coa-single-en", UINT64_C(0xf85c29bdaa0feab3), UINT64_C(0x8599957f814638b0), 214, 194, 250, 13},
    /* Original English 950 pages use the short wizard at y339..360.
     * Public instructions distinguish its waiting hardware page from the
     * identically titled active detection page immediately below it. */
    {"directory-en", UINT64_C(0x6f912fd406d2f9bc), UINT64_C(0x1efd71610cab5ab7), 214, 129, 365, 43},
    {"setup-type-en", UINT64_C(0x2947e7a7c49e592b), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"owner-en", UINT64_C(0x527862c5a3c2b2fd), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"hardware-list-en", UINT64_C(0x53da302148d1cd16), UINT64_C(0x1bb3e37e9b89f815), 214, 129, 365, 43},
    {"busy", UINT64_C(0x53da302148d1cd16), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"communication-en", UINT64_C(0xff6d4a3e8fb49f38), UINT64_C(0x6e929060547d2e3a), 214, 129, 365, 43},
    {"components-en", UINT64_C(0xba085e9f60e1ec03), UINT64_C(0xd89f1aceaf9f1a8d), 214, 129, 365, 43},
    {"copy-ready-en", UINT64_C(0x5cc7b92f00ccacb7), UINT64_C(0x47ead39e433c9b6d), 214, 129, 365, 43},
    /* Exact Network adapters selector; cancel through the visible button
     * instead of installing the old detected NDIS2/ODI placeholder. */
    {"network-device-en", UINT64_C(0x546e6568cf8848ff), UINT64_C(0xdf22bf26597d0dce), 74, 45, 453, 38},
    /* RTM PL OEM: single Product ID edit; labels only, edit at y=235 excluded. */
    {"coa-single", UINT64_C(0xa31becc465840cd2), UINT64_C(0x2983c7270b2212f1), 214, 212, 260, 16},
    {"recovery", UINT64_C(0x5f7deb30089843a5), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"welcome", UINT64_C(0x876af5e9289567a9), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"busy", UINT64_C(0x1f36e2daa8666765), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"busy", UINT64_C(0x04017a8b5487ec68), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"setup-type", UINT64_C(0x65cb873cd593e64e), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    /* Exact RTM PL OEM heading: Opcje programu Instalator. */
    {"setup-type", UINT64_C(0xa07c4a33fc5c5f22), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"coa", UINT64_C(0x57899c67caef5944), UINT64_C(0x46071c2c8bdb3bc3), 110, 138, 405, 16},
    {"owner", UINT64_C(0x202c4cd89699d426), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"hardware-list", UINT64_C(0xf9ce3d026135a826), UINT64_C(0xe677e0878975fb18), 214, 129, 365, 43},
    {"busy", UINT64_C(0xf9ce3d026135a826), UINT64_C(0xa5eaef2d71e6f47f), 214, 129, 365, 43},
    /* RTM PL adds Communication before the common Windows components page. */
    {"communication", UINT64_C(0x5ddbfc6d53f04a7c), UINT64_C(0x71b411b0d5813505), 54, 90, 160, 24},
    {"components", UINT64_C(0xb8c2ba9fa19c2f01), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"computer-options", UINT64_C(0xb0f529c4eee43ea6), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"startup-disk", UINT64_C(0x6abd2d2621e3dec0), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"copy-ready", UINT64_C(0x01e2d224e94e7454), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"busy", UINT64_C(0x71ada2dbbfd4fc8d), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
    {"restart", UINT64_C(0xb8966280dd8b189a), UINT64_C(0x7ea17a0dc876890d), 130, 168, 376, 23},
    /* RTM PL first Finish text; the following reboot confirmation is shared. */
    {"restart", UINT64_C(0xb8966280dd8b189a), UINT64_C(0x2ea8d56e74180678), 130, 168, 376, 23},
    {"reboot-confirm", UINT64_C(0xb8966280dd8b189a), UINT64_C(0xf91a3f1cbb37d3a1), 130, 168, 376, 23},
    {"directory", UINT64_C(0xc1f50b8b63695fb6), UINT64_C(0x0000000000000000), 0, 0, 0, 0},
};
