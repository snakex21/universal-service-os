const serial = @import("serial");

pub fn main() void {
    serial.init();
    serial.writeAscii("DIRECT EFI VALIDATION PASS\n");
}
