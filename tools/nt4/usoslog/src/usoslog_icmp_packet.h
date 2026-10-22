/* Validate a raw IPv4 echo reply against this probe's complete request.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 */
static WORD echo_checksum(const BYTE *data, DWORD n)
{
    DWORD sum = 0, i;
    for (i = 0; i + 1 < n; i += 2) sum += ((DWORD)data[i] << 8) | data[i + 1];
    if (n & 1) sum += (DWORD)data[n - 1] << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (WORD)~sum;
}

static int echo_matches(const BYTE *packet, DWORD length, DWORD peer,
                        DWORD expected_peer, const BYTE *request, DWORD request_length)
{
    DWORD header, total, source, i;
    const BYTE *reply;
    if (length < 20 || request_length < 8 || peer != expected_peer) return 0;
    header = (DWORD)(packet[0] & 15) * 4;
    if ((packet[0] >> 4) != 4 || header < 20 || header > 60 || header > length) return 0;
    total = ((DWORD)packet[2] << 8) | packet[3];
    if (total < header || total > length || total - header != request_length || packet[9] != 1) return 0;
    if ((packet[6] & 0x3f) || packet[7]) return 0; /* MF or a fragment offset */
    mcpy(&source, packet + 12, sizeof(source));
    if (source != expected_peer) return 0;
    reply = packet + header;
    if (reply[0] || reply[1] || echo_checksum(reply, request_length)) return 0;
    for (i = 4; i < request_length; i++) if (reply[i] != request[i]) return 0;
    return 1;
}
