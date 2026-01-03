```text
Usage:
  ./run_qemu.sh [command]

Commands:
  deps      Install build dependencies (Ubuntu/Debian: apt). Uses sudo if needed.
  build     Download + build Linux kernel and BusyBox; generate initramfs.
  run       Run QEMU with built kernel + initramfs.
  uefi      Create UEFI bootable disk image and run with QEMU.
  clean     Remove work/ directory.

Default (no command): build + run
