# Emit Setup's migration map from the verified MBR signature and partition LBAs.
# MBR volume identity = four signature bytes + eight-byte little-endian offset.
function fail(message) { print "XP drive letters: " message > "/dev/stderr"; exit 1 }
function valid_lba(value) { return value ~ /^[0-9]+$/ && value > 0 && value <= 4294967295 }
function mapping(letter, lba, offset, i) {
    printf "HKLM,\"SYSTEM\\MountedDevices\",\"\\DosDevices\\%s:\",0x00030001", letter
    for (i = 1; i <= 8; i += 2) printf ",%s", substr(signature, i, 2)
    offset = lba * 512
    for (i = 0; i < 8; i++) {
        printf ",%02x", offset % 256
        offset = int(offset / 256)
    }
    printf "\r\n"
}
BEGIN {
    if (length(signature) != 8 || signature ~ /[^0-9a-fA-F]/ || signature == "00000000") fail("invalid disk signature")
    if (!valid_lba(windows_start)) fail("invalid partition offset")
    printf "[Version]\r\nSignature = \"$Windows NT$\"\r\n\r\n[AddReg]\r\n"
    mapping("C", windows_start)
    exit 0
}
