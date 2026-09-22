"""Exercise production BIOS resume on disposable images; inputs remain read-only."""
import argparse, hashlib, json, socket, struct, subprocess, time
from pathlib import Path
from fat32_test_image import FatImage

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--usos",type=Path,required=True)
    p.add_argument("--target",type=Path,required=True)
    p.add_argument("--target-format",default="vdi")
    p.add_argument("--output",type=Path,required=True)
    p.add_argument("--case",choices=["success","wrong-serial","wrong-id","before-text"],default="success")
    p.add_argument("--direct-linux", action="store_true", help="Test current resume backend without replacing a smaller fixture initramfs")
    a=p.parse_args()
    root=Path(__file__).resolve().parents[3]
    out=a.output.resolve(); out.mkdir(parents=True,exist_ok=False)
    qi=root/"tools/qemu/qemu-img.exe"
    def run(*args): subprocess.run([str(qi),*map(str,args)],check=True,capture_output=True)
    usos=out/"usos.raw"; target=out/"target.qcow2"
    run("convert","-f","qcow2","-O","raw",a.usos.resolve(),usos)
    run("create","-f","qcow2","-F",a.target_format,"-b",a.target.resolve(),target)
    run("dd","-f",a.target_format,"-O","raw","if="+str(a.target.resolve()),"of="+str(out/"before.bin"),"bs=512","count=1")
    before=(out/"before.bin").read_bytes()
    info=json.loads(subprocess.check_output([str(qi),"info","--output=json",str(a.target.resolve())]))
    diskid="0x%08x"%struct.unpack_from("<I",before,440)[0]
    fat=FatImage(usos)
    marker=fat.contents("EFI/USOS/xp-resume.ini").decode()
    state=dict(line.split("=",1) for line in marker.splitlines() if "=" in line)
    assert state["version"]=="2" and state["serial"]=="XP-TARGET-A"
    state["mbr_disk_id"]=diskid if a.case!="wrong-id" else "0x00000001"
    state["size_bytes"]=str(info["virtual-size"])
    if a.case=="wrong-serial": state["serial"]="WRONG-TARGET"
    fat.replace("EFI/USOS/xp-resume.ini",("\n".join(k+"="+v for k,v in state.items())+"\n").encode())
    device_ini=dict(line.split("=",1) for line in fat.contents("EFI/USOS/usos-device.ini").decode().splitlines() if "=" in line)
    if not a.direct_linux:
        fat.replace("EFI/USOS/micro-linux/initramfs-usos",(root/"zig-out/micro-linux/initramfs-usos").read_bytes())
    fat.close()
    with usos.open("r+b") as f:
        f.write((root/"zig-out/legacy-bios/stage1.bin").read_bytes())
        f.seek(64*512); f.write((root/"zig-out/legacy-bios/core-slot.bin").read_bytes())
    with socket.socket() as s: s.bind(("127.0.0.1",0)); port=s.getsockname()[1]
    serial=out/"serial.log"
    args=[str(root/"tools/qemu/qemu-system-x86_64.exe"),"-name","USOS-XP-Resume-Test","-machine","pc","-accel","tcg,thread=multi","-cpu","max","-m","512M","-smp","2","-display","none","-vga","std","-nic","none","-monitor",f"tcp:127.0.0.1:{port},server=on,wait=off","-serial","file:"+str(serial),"-drive","if=ide,index=0,format=raw,file="+str(usos),"-drive","if=none,id=xptarget,format=qcow2,file="+str(target),"-device","ide-hd,bus=ide.0,unit=1,drive=xptarget,serial=XP-TARGET-A"]
    if a.direct_linux:
        args += ["-kernel", str(root/"zig-out/micro-linux/vmlinuz-virt"), "-initrd", str(root/"zig-out/micro-linux/initramfs-usos"), "-append", "console=ttyS0,115200 rdinit=/usos-init usos.legacy_action=xp-resume usos.esp_partuuid="+device_ini["esp_partuuid"]]
    def hmp(command):
        with socket.create_connection(("127.0.0.1",port)) as s:
            s.sendall((command+"\n").encode()); time.sleep(.3)
    def wait(needle,seconds=120):
        until=time.monotonic()+seconds
        while time.monotonic()<until:
            text=serial.read_text(errors="replace") if serial.exists() else ""
            if needle in text: return text
            if proc.poll() is not None: raise RuntimeError("QEMU exited: "+text[-2000:])
            if "[MICRO-LINUX] STOP:" in text and needle!="[MICRO-LINUX] STOP:": raise RuntimeError(text[-2000:])
            time.sleep(.2)
        raise TimeoutError(needle+"\n"+text[-3000:])
    with (out/"stderr.log").open("w") as err:
        proc=subprocess.Popen(args,stderr=err,stdout=err,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
        try:
            if not a.direct_linux:
                wait("XP RESUME AVAILABLE")
                hmp('screendump "'+str(out/"prompt.ppm").replace("\\","/")+'"')
                # ESC returns to a usable normal menu. Restart to exercise ENTER.
                hmp("sendkey esc"); time.sleep(.5)
                hmp('screendump "'+str(out/"menu-after-esc.ppm").replace("\\","/")+'"')
                hmp("system_reset")
                until=time.monotonic()+30
                while time.monotonic()<until:
                    if serial.read_text(errors="replace").count("XP RESUME AVAILABLE") >= 2: break
                    time.sleep(.2)
                else: raise TimeoutError("resume prompt did not return after reset")
                hmp("sendkey ret")
            expected="[XP_RESUME] Remove USOS USB" if a.case=="success" else "[MICRO-LINUX] STOP:"
            wait(expected,180)
            hmp('screendump "'+str(out/"result.ppm").replace("\\","/")+'"')
        finally:
            if proc.poll() is None:
                try: hmp("quit")
                except OSError: pass
                try: proc.wait(timeout=10)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    fat=FatImage(usos)
    log=fat.contents("EFI/USOS/legacy-xp-resume.log").decode(errors="replace")
    (out/"resume.log").write_text(log)
    fat.close()
    run("dd","-f","qcow2","-O","raw","if="+str(target),"of="+str(out/"after.bin"),"bs=512","count=1")
    after=(out/"after.bin").read_bytes()
    if a.case=="success":
        assert "[XP_RESUME] PASS" in log,log
        assert after[:440]==(root/"zig-out/xp-geometry-fix-mbr/xp-geometry-fix-mbr-440.bin").read_bytes()
        assert after[440:]==before[440:]
    else:
        assert "[XP_RESUME] STOP:" in log,log
        assert after==before,"Rejected request changed MBR"
        # Compare all logical bytes against the original backing image.
        run("compare","-f",a.target_format,"-F","qcow2",a.target.resolve(),target)
    print(log)
    print("[PASS] case="+a.case+" output="+str(out))
if __name__=="__main__": main()
