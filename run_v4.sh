#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# QEMU AMD64 Linux "hello world" system builder/runner
# Host tested target: Ubuntu 22.04 (apt). No writes outside this working dir.
# Produces:
#   work/linux-6.12.63/arch/x86/boot/bzImage
#   work/rootfs.cpio.gz
# Runs:
#   qemu-system-x86_64 ... -kernel bzImage -initrd rootfs.cpio.gz ...
#   OR the UEFI version
# ------------------------------------------------------------------------------

KVER="6.12.63"
BBVER="1_36_1"

TOP="$(pwd)"
WORK="$TOP/work"

LINUX_TARBALL="linux-$KVER.tar.xz"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/$LINUX_TARBALL"
BUSYBOX_TARBALL="$BBVER.tar.gz"
BUSYBOX_URL="https://github.com/mirror/busybox/archive/refs/tags/$BUSYBOX_TARBALL"

ROOTFS="$WORK/rootfs"
CPIO_GZ="$WORK/rootfs.cpio.gz"
DISK_IMG="$WORK/disk.img"

# QEMU defaults
MEM="256M"
APPEND="console=ttyS0 rdinit=/sbin/init"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

# UEFI firmware path
OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"

usage() {
  cat <<EOF
Usage:
  ./run.sh [command]

Commands:
  deps      Install build dependencies (Ubuntu/Debian: apt). Uses sudo if needed.
  build     Download + build Linux kernel and BusyBox; generate initramfs.
  run       Run QEMU with built kernel + initramfs.
  uefi      Create UEFI bootable disk image and run with QEMU.
  clean     Remove work/ directory.

Default (no command): build + run
EOF
}

ensure_dirs() {
  mkdir -p "$WORK"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

download_if_missing() {
  local url="$1"
  local dst="$2"
  if [[ -f "$dst" ]]; then
    echo "[+] Using cached: $dst"
    return 0
  fi
  echo "[+] Downloading: $url"
  if have_cmd curl; then
    curl -L --fail -o "$dst" "$url"
  elif have_cmd wget; then
    wget -O "$dst" "$url"
  else
    echo "[-] Need curl or wget to download tarballs." >&2
    exit 1
  fi
}

install_deps_ubuntu() {
  local pkgs=(
    build-essential
    bc
    bison
    flex
    libelf-dev
    libssl-dev
    libncurses-dev
    dwarves
    pkg-config
    rsync
    cpio
    gzip
    xz-utils
    bzip2
    qemu-system-x86
    qemu-utils
    ca-certificates
    curl
    grub-efi-amd64-bin
    grub-pc-bin
    ovmf
    dosfstools
    parted
  )

  echo "[+] Installing dependencies via apt (Ubuntu/Debian)..."
  if [[ $EUID -ne 0 ]]; then
    sudo apt-get update
    sudo apt-get install -y "${pkgs[@]}"
  else
    apt-get update
    apt-get install -y "${pkgs[@]}"
  fi
}

deps() {
  if have_cmd apt-get; then
    install_deps_ubuntu
  else
    cat <<EOF
[-] Non-apt distro detected.
    Please install equivalents of:
      gcc/g++/make (build-essential), bc, bison, flex, libelf-dev, libssl-dev,
      libncurses-dev, dwarves (pahole), pkg-config, rsync, cpio, gzip, xz, bzip2,
      qemu-system-x86_64 (or qemu-system-x86), curl/wget, ca-certificates,
      grub-efi-amd64-bin, grub-pc-bin, ovmf, dosfstools, parted
EOF
    exit 1
  fi
}

extract_if_missing() {
  local tarball="$1"
  local destdir="$2"
  local marker="$3"
  if [[ -e "$marker" ]]; then
    echo "[+] Already extracted: $destdir"
    return 0
  fi
  echo "[+] Extracting: $tarball"
  rm -rf "$destdir"
  mkdir -p "$destdir"
  tar -xf "$tarball" -C "$WORK"
}

# Attach the UEFI disk image as a loop device and expose its partitions.
attach_loop() {
    local loop
    loop=$(sudo losetup --show -fP "$DISK_IMG") || return 1
    echo "$loop"
}

# Detach a previously attached loop device.
detach_loop() {
    local loop="$1"
    sudo losetup -d "$loop" 2>/dev/null || true
}

# Safely unmount EFI/root mount points and detach the loop device.
cleanup_mounts() {
    local mnt_efi="$1"
    local mnt_root="$2"
    local loop="$3"
    
    # EFI sync + delay
    if mountpoint -q "$mnt_efi"; then
        sudo sync 
        sleep 0.5 
        sudo umount "$mnt_efi" 2>/dev/null || {
            echo "[uefi] First umount attempt failed, forcing..."
            sudo umount -f "$mnt_efi" 2>/dev/null || {
                echo "[uefi] Force umount failed, trying lazy umount..."
                sudo umount -l "$mnt_efi"
            }
        }
    fi
    
    if mountpoint -q "$mnt_root"; then
        sudo umount "$mnt_root" 2>/dev/null || sudo umount -f "$mnt_root"
    fi
    
    detach_loop "$loop"
}

build_kernel() {
  local linux_dir="$WORK/linux-$KVER"
  local bz="$linux_dir/arch/x86/boot/bzImage"

  if [[ -f "$bz" ]]; then
    echo "[+] Kernel already built: $bz"
    return 0
  fi

  echo "[+] Building Linux kernel $KVER"
  pushd "$linux_dir" >/dev/null

  make defconfig

  if [[ -x scripts/config ]]; then
    scripts/config --enable SERIAL_8250
    scripts/config --enable SERIAL_8250_CONSOLE
    scripts/config --enable TTY
    scripts/config --enable UNIX
    scripts/config --enable DEVTMPFS
    scripts/config --enable DEVTMPFS_MOUNT
    scripts/config --enable BLK_DEV_INITRD
    scripts/config --enable BLK_DEV_SD
  fi

  make -j"$(nproc)"

  if [[ ! -f "$bz" ]]; then
    echo "[-] bzImage not produced. Check kernel build output." >&2
    exit 1
  fi

  popd >/dev/null
}

build_busybox_static() {
  local bb_dir="$WORK/busybox-$BBVER"
  local bb_bin="$bb_dir/busybox"

  if [[ -x "$bb_bin" ]]; then
    echo "[+] BusyBox already built: $bb_bin"
    return 0
  fi

  echo "[+] Building BusyBox $BBVER (static)"
  pushd "$bb_dir" >/dev/null

  make distclean || true
  make defconfig

  if grep -q '^# CONFIG_STATIC is not set' .config; then
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
  elif ! grep -q '^CONFIG_STATIC=y' .config; then
    echo 'CONFIG_STATIC=y' >> .config
  fi

  make -j"$(nproc)"
  popd >/dev/null
}

make_rootfs() {
  echo "[+] Creating rootfs in: $ROOTFS"
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"

  mkdir -p \
    "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,tmp,usr/{bin,sbin},var,root,home} \
    "$ROOTFS"/etc/init.d

  chmod 0755 "$ROOTFS"
  chmod 1777 "$ROOTFS/tmp"

  local bb_dir="$WORK/busybox-$BBVER"
  pushd "$bb_dir" >/dev/null
  make CONFIG_PREFIX="$ROOTFS" install
  popd >/dev/null

  ln -sf /bin/busybox "$ROOTFS/bin/sh"

  cat >"$ROOTFS/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rcS
::respawn:-/bin/sh
::restart:/sbin/init
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/sync
EOF

  cat >"$ROOTFS/etc/init.d/rcS" <<'EOF'
#!/bin/sh
# Minimal init script for QEMU initramfs
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Hello World
/bin/echo -e "\n================================\n       HELLO WORLD!\n================================\n"

EOF
  chmod +x "$ROOTFS/etc/init.d/rcS"
}

pack_initramfs() {
  echo "[+] Packing initramfs: $CPIO_GZ"
  rm -f "$CPIO_GZ"
  ( cd "$ROOTFS" && find . -print0 | cpio --null -ov --format=newc ) | gzip -9 >"$CPIO_GZ"
}

build_all() {
  ensure_dirs

  download_if_missing "$LINUX_URL" "$WORK/$LINUX_TARBALL"
  download_if_missing "$BUSYBOX_URL" "$WORK/busybox-$BUSYBOX_TARBALL"

  extract_if_missing "$WORK/$LINUX_TARBALL" "$WORK/linux-$KVER" "$WORK/linux-$KVER/Makefile"
  extract_if_missing "$WORK/busybox-$BUSYBOX_TARBALL" "$WORK/busybox-$BBVER" "$WORK/busybox-$BBVER/Makefile"

  build_kernel
  build_busybox_static

  make_rootfs
  pack_initramfs

  echo "[+] Build completed."
  echo "    Kernel: $WORK/linux-$KVER/arch/x86/boot/bzImage"
  echo "    Initrd: $CPIO_GZ"
}

run_qemu() {
  local bz="$WORK/linux-$KVER/arch/x86/boot/bzImage"
  if [[ ! -f "$bz" || ! -f "$CPIO_GZ" ]]; then
    echo "[-] Missing artifacts. Run: ./run.sh build" >&2
    exit 1
  fi

  if ! have_cmd "$QEMU_BIN"; then
    echo "[-] $QEMU_BIN not found. Install qemu-system-x86 (Ubuntu) or equivalent." >&2
    exit 1
  fi

  echo "[+] Running QEMU..."
  exec "$QEMU_BIN" \
    -m "$MEM" \
    -kernel "$bz" \
    -initrd "$CPIO_GZ" \
    -append "$APPEND" \
    -nographic
}

create_uefi_disk() {
  local kernel="$WORK/linux-$KVER/arch/x86/boot/bzImage"
  local initrd="$CPIO_GZ"
  
  if [[ ! -f "$kernel" || ! -f "$initrd" ]]; then
    echo "[-] Missing kernel or initrd. Run: ./run.sh build" >&2
    exit 1
  fi

  echo "[+] Creating UEFI bootable disk image..."
  
  # Create disk image (128MB)
  dd if=/dev/zero of="$DISK_IMG" bs=1M count=128 2>/dev/null
  
  # Create GPT partition table
  sudo parted "$DISK_IMG" mklabel gpt
  
  # EFI System Partition (ESP) - first 64MB
  sudo parted "$DISK_IMG" mkpart ESP fat32 1MiB 64MiB
  sudo parted "$DISK_IMG" set 1 esp on
  
  # Root partition - remaining space
  sudo parted "$DISK_IMG" mkpart primary ext4 64MiB 100%
  
  # Setup loop device
  sudo losetup -fP "$DISK_IMG"
  local loop_dev=$(sudo losetup -j "$DISK_IMG" | cut -d: -f1)
  
  if [[ -z "$loop_dev" ]]; then
    echo "[-] Failed to create loop device" >&2
    exit 1
  fi
  
  echo "[+] Using loop device: $loop_dev"
  
  # Format partitions
  sudo mkfs.fat -F 32 "${loop_dev}p1"
  sudo mkfs.ext4 -q "${loop_dev}p2"
  
  # Create mount points
  local mnt_efi="$WORK/mnt_efi"
  local mnt_root="$WORK/mnt_root"
  mkdir -p "$mnt_efi" "$mnt_root"
  
  # Mount partitions
  sudo mount "${loop_dev}p1" "$mnt_efi"
  sudo mount "${loop_dev}p2" "$mnt_root"
  
  # Create directory structure
  sudo mkdir -p "$mnt_efi/EFI/BOOT"
  sudo mkdir -p "$mnt_efi/boot/grub"
  sudo mkdir -p "$mnt_root/boot"
  
  sudo rsync -a "$ROOTFS"/ "$mnt_root"/
  
  # Install GRUB
  echo "[+] Installing GRUB..."
  sudo grub-install \
    --target=x86_64-efi \
    --efi-directory="$mnt_efi" \
    --boot-directory="$mnt_efi/boot" \
    --removable \
    --no-nvram \
    --recheck
  
  if [[ $? -ne 0 ]]; then
    echo "[-] GRUB installation failed" >&2
    cleanup_mounts "$mnt_efi" "$mnt_root" "$loop_dev"
    exit 1
  fi
  
  # Copy kernel and initrd
  echo "[+] Copying kernel and initrd..."
  sudo cp "$kernel" "$mnt_efi/boot/vmlinuz"
  sudo cp "$initrd" "$mnt_efi/boot/initrd.gz"
  
  # Create GRUB configuration
  sudo tee "$mnt_efi/boot/grub/grub.cfg" > /dev/null <<'EOF'
set timeout=3
set default=0

# Console settings for UEFI
terminal_input console
terminal_output console

menuentry "Hello World Linux" {
    echo "Loading kernel..."
    linux /boot/vmlinuz console=ttyS0 root=/dev/sda2 rootfstype=ext4 rw #rdinit=/sbin/init
    echo "Loading initrd..."
    initrd /boot/initrd.gz
    echo "Booting..."
}
EOF
  
  # Cleanup
  echo "[+] Cleaning up..."
  cleanup_mounts "$mnt_efi" "$mnt_root" "$loop_dev"
  
  echo "[+] UEFI disk image created: $DISK_IMG"
}

grow_root_partition() {
    local loop="$1"

    echo "[uefi] Growing disk image and root partition..."

    # 1) Double the raw disk image size.
    local img_size new_size
    img_size=$(stat -c%s "$DISK_IMG") || return 1
    new_size=$(( img_size * 2 ))

    echo "[uefi] Resizing disk image from $img_size bytes to $new_size bytes"
    qemu-img resize -f raw "$DISK_IMG" "$new_size"

    # 2) Re-attach loop device so the kernel sees the new size.
    detach_loop "$loop" 2>/dev/null || true
    loop=$(attach_loop) || return 1
    echo "[uefi] Re-attached loop device: $loop"
    
    echo "[uefi] Fixing GPT metadata to use full disk size..."
    if command -v sgdisk >/dev/null 2>&1; then
      sudo sgdisk -e "$loop"
    else
      # Fallback: a 'print' on parted often auto-fixes GPT in non-interactive mode
      sudo parted -s "$loop" "print" >/dev/null 2>&1 || true
    fi

    # 3) Enlarge partition 2 to 100% of the disk using parted.
    #    We use 'unit %' so '100' means "100% of the disk".
    echo "[uefi] Resizing partition 2 to 100% of disk..."
    sudo parted -s "$loop" "resizepart 2 100%" || {
      echo "[-] parted failed to resize partition 2" >&2
      return 1
    }

    # 4) Notify the kernel about partition changes.
    sudo partprobe "$loop" || true

    # 5) Grow the ext4 filesystem inside partition 2.
    local rootpart="${loop}p2"
    echo "[uefi] Running e2fsck and resize2fs on $rootpart..."
    sudo e2fsck -f -y "$rootpart" || true
    sudo resize2fs "$rootpart"

    echo "[uefi] Root partition successfully grown."
    return 0
}

# Validate the existing UEFI disk image:
#  - check partition table,
#  - run fsck,
#  - mount EFI and root,
#  - check critical files,
#  - check usage and auto-grow if >= 90%.
# Returns 0 on success, non-zero if the disk looks invalid.
validate_and_maybe_grow_disk() {
    local loop
    loop=$(attach_loop) || return 1
    echo "[uefi] Using loop device for validation: $loop"

    # 1) Check if parted can read the partition table.
    if ! sudo parted -s "$loop" print >/dev/null 2>&1; then
        echo "[uefi] parted cannot read partition table" >&2
        detach_loop "$loop"
        return 1
    fi

    # 2) Ensure expected partitions exist: p1 (EFI), p2 (root).
    if [ ! -b "${loop}p1" ] || [ ! -b "${loop}p2" ]; then
        echo "[uefi] Expected partitions p1 (EFI) and p2 (root) not found" >&2
        detach_loop "$loop"
        return 1
    fi

    # 3) Run filesystem checks (non-interactive).
    echo "[uefi] Running fsck on EFI (vfat) and root (ext4)..."
    sudo fsck.vfat -a "${loop}p1" >/dev/null 2>&1 || true
    sudo e2fsck -p "${loop}p2"   >/dev/null 2>&1 || true

    # 4) Mount partitions.
    local mnt_efi="$WORK/mnt_efi"
    local mnt_root="$WORK/mnt_root"
    mkdir -p "$mnt_efi" "$mnt_root"

    if ! sudo mount "${loop}p1" "$mnt_efi"; then
        echo "[uefi] Failed to mount EFI partition" >&2
        detach_loop "$loop"
        return 1
    fi

    if ! sudo mount "${loop}p2" "$mnt_root"; then
        echo "[uefi] Failed to mount root partition" >&2
        if mountpoint -q "$mnt_efi"; then
            sudo sync 
            sleep 0.5 
            sudo umount "$mnt_efi" 2>/dev/null || {
                echo "[uefi] First umount attempt failed, forcing..."
                sudo umount -f "$mnt_efi" 2>/dev/null || {
                    echo "[uefi] Force umount failed, trying lazy umount..."
                    sudo umount -l "$mnt_efi"
                }
            }
        fi
        detach_loop "$loop"
        return 1
    fi

    # 5) Check critical files exist.
    if [ ! -f "$mnt_efi/EFI/BOOT/BOOTX64.EFI" ]; then
        echo "[uefi] Missing EFI/BOOT/BOOTX64.EFI" >&2
        cleanup_mounts "$mnt_efi" "$mnt_root" "$loop"
        return 1
    fi
    if [ ! -f "$mnt_efi/boot/vmlinuz" ]; then
        echo "[uefi] Missing /boot/vmlinuz in efi partition" >&2
        cleanup_mounts "$mnt_efi" "$mnt_root" "$loop"
        return 1
    fi
    if [ ! -f "$mnt_efi/boot/initrd.gz" ]; then
        echo "[uefi] Missing /boot/initrd.gz in efi partition" >&2
        cleanup_mounts "$mnt_efi" "$mnt_root" "$loop"
        return 1
    fi

    # 6) Check root filesystem usage.
    local used_pct
    used_pct=$(df --output=pcent "$mnt_root" | tail -n1 | tr -dc '0-9')
    echo "[uefi] Root filesystem usage: ${used_pct}%"

    if [ "$used_pct" -ge 90 ]; then
        echo "[uefi] Root filesystem is >= 90% full, attempting to grow..."
        # Unmount before resizing.
        if mountpoint -q "$mnt_efi"; then
            sudo sync 
            sleep 0.5 
            sudo umount "$mnt_efi" 2>/dev/null || {
                echo "[uefi] First umount attempt failed, forcing..."
                sudo umount -f "$mnt_efi" 2>/dev/null || {
                    echo "[uefi] Force umount failed, trying lazy umount..."
                    sudo umount -l "$mnt_efi"
                }
            }
        fi
    
        if mountpoint -q "$mnt_root"; then
            sudo umount "$mnt_root" 2>/dev/null || sudo umount -f "$mnt_root"
        fi

        if ! grow_root_partition "$loop"; then
            echo "[uefi] Failed to grow root partition" >&2
            detach_loop "$loop"
            return 1
        fi

        detach_loop "$loop"
        return 0
    fi

    # Normal case: everything looks fine and we do not need to grow.
    cleanup_mounts "$mnt_efi" "$mnt_root" "$loop"
    return 0
}

# Ensure we have a valid UEFI disk image:
#  - if it does not exist => create a fresh one,
#  - if it exists        => validate and auto-grow if needed,
#  - if validation fails => recreate from scratch.
check_or_prepare_uefi_disk() {
    if [ ! -f "$DISK_IMG" ]; then
        echo "[uefi] Disk image not found, creating a fresh UEFI disk..."
        create_uefi_disk
        return $?
    fi

    echo "[uefi] Disk image exists, validating and checking usage..."
    if ! validate_and_maybe_grow_disk; then
        echo "[uefi] Disk image appears invalid; recreating..." >&2
        rm -f "$DISK_IMG"
        create_uefi_disk
    fi
}

run_uefi() {
  if [[ ! -f "$DISK_IMG" ]]; then
    echo "[-] Disk image not found. Creating it first..." >&2
    create_uefi_disk
  fi
  
  if [[ ! -f "$OVMF_CODE" ]]; then
    echo "[-] OVMF firmware not found at: $OVMF_CODE" >&2
    echo "    Install ovmf package or update OVMF_CODE path" >&2
    exit 1
  fi
  
  if ! have_cmd "$QEMU_BIN"; then
    echo "[-] $QEMU_BIN not found. Install qemu-system-x86 (Ubuntu) or equivalent." >&2
    exit 1
  fi
  
  echo "[+] Running QEMU with UEFI..."
  exec "$QEMU_BIN" \
    -m "$MEM" \
    -drive file="$DISK_IMG",format=raw,cache=none \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -nographic \
    -serial mon:stdio
}

uefi_command() {
  # Ensure build artifacts exist
  local kernel="$WORK/linux-$KVER/arch/x86/boot/bzImage"
  if [[ ! -f "$kernel" || ! -f "$CPIO_GZ" ]]; then
    echo "[+] Build artifacts missing. Building first..."
    build_all
  fi
  
  check_or_prepare_uefi_disk
  run_uefi
}

clean() {
  echo "[+] Removing: $WORK"
  rm -rf "$WORK"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    -h|--help) usage ;;
    deps) deps ;;
    build) build_all ;;
    run) run_qemu ;;
    uefi) uefi_command ;;
    clean) clean ;;
    "")
      build_all
      run_qemu
      ;;
    *)
      echo "[-] Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
