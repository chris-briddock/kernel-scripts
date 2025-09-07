#!/usr/bin/env bash
set -euo pipefail

# ===============================================
# CONFIG
# ===============================================
KERNEL_VER="6.16.5-lqx1"
KERNEL_URL="https://github.com/zen-kernel/zen-kernel/archive/refs/tags/v${KERNEL_VER}.zip"
KERNEL_ARCHIVE="zen-kernel-${KERNEL_VER}.zip"
KERNEL_SRC="zen-kernel-${KERNEL_VER}"
MOK_DIR="/home/chris/mok-keys"
MOK_KEY="${MOK_DIR}/MOK.key"
MOK_PEM="${MOK_DIR}/MOK.pem"
MOK_DER="${MOK_DIR}/MOK.der"

# ===============================================
# PREP
# ===============================================
echo "==> Installing build dependencies..."
sudo pacman -S --needed base-devel git unzip wget bc kmod cpio flex bison \
  openssl zstd pahole xz perl tar sbsigntools mokutil

# ===============================================
# DOWNLOAD
# ===============================================
if [ ! -f "$KERNEL_ARCHIVE" ]; then
  echo "==> Downloading Zen kernel v${KERNEL_VER}..."
  wget -O "$KERNEL_ARCHIVE" "$KERNEL_URL"
fi

if [ ! -d "$KERNEL_SRC" ]; then
  echo "==> Extracting kernel sources..."
  unzip "$KERNEL_ARCHIVE"
fi

cd "$KERNEL_SRC"

# ===============================================
# CONFIGURE
# ===============================================
echo "==> Setting up kernel config..."
if [ -f /proc/config.gz ]; then
    zcat /proc/config.gz > .config
else
    echo "⚠️ /proc/config.gz not found, using defconfig"
    make defconfig
fi
echo "==> Base config written to .config"

# -----------------------------
# HARDENING FLAGS
# -----------------------------
echo "==> Applying hardening flags..."
scripts/config --enable STACKPROTECTOR_STRONG
scripts/config --enable FORTIFY_SOURCE
scripts/config --enable REFCOUNT_FULL
scripts/config --enable GCC_PLUGIN_RANDSTRUCT
scripts/config --enable GCC_PLUGIN_STACKLEAK
scripts/config --enable INIT_STACK_ALL_ZERO
scripts/config --enable SECURITY
scripts/config --enable SECURITY_YAMA
scripts/config --enable SECURITY_YAMA_STACKED
scripts/config --enable HARDENED_USERCOPY
scripts/config --set-val FORTIFY_SOURCE 2
scripts/config --enable RANDOMIZE_BASE
scripts/config --enable STRICT_KERNEL_RWX

# -----------------------------
# KERNEL LOCKDOWN
# -----------------------------
echo "==> Applying kernel lockdown"
scripts/config --enable LOCK_DOWN_KERNEL
scripts/config --enable LOCK_DOWN_KERNEL_FORCE_INTEGRITY
scripts/config --disable LOCK_DOWN_KERNEL_FORCE_NONE

# -----------------------------
# DISABLE KEXEC / ALTERNATE KERNEL LOADING
# -----------------------------
echo "==> Disabling kernel replacement (kexec, crash dump)"
scripts/config --disable KEXEC
scripts/config --disable KEXEC_FILE
scripts/config --disable KEXEC_SIG
scripts/config --disable KEXEC_CORE
scripts/config --disable CRASH_DUMP

# -----------------------------
# DISABLE DEBUG / LEGACY FEATURES
# -----------------------------
echo "==> Disabling legacy/debug features"
scripts/config --disable BINFMT_MISC
scripts/config --disable LEGACY_PTYS
scripts/config --disable PROC_KCORE
scripts/config --disable DEV_COREDUMP
scripts/config --disable DEBUG_KERNEL
scripts/config --disable KALLSYMS
scripts/config --disable KALLSYMS_ALL
scripts/config --disable DEBUG_INFO
scripts/config --disable MAGIC_SYSRQ
scripts/config --disable PROC_VMCORE
scripts/config --disable BUG
scripts/config --disable PTRACE
scripts/config --disable DEBUG_MISC
scripts/config --disable PERF_EVENTS
scripts/config --disable DEVKMEM
scripts/config --disable DEVMEM
scripts/config --disable KGDB
scripts/config --disable KDB
scripts/config --disable DEBUG_INFO_BTF
scripts/config --disable DEBUG_INFO_REDUCED
scripts/config --disable FTRACE
scripts/config --disable FUNCTION_TRACER
scripts/config --disable FUNCTION_GRAPH_TRACER
scripts/config --disable KPROBES
scripts/config --disable UPROBES
scripts/config --disable BPF_SYSCALL
scripts/config --disable HAVE_EBPF_JIT
scripts/config --disable BPF_JIT
scripts/config --disable PROC_PAGE_MONITOR
scripts/config --disable USERFAULTFD
scripts/config --disable KEYS
scripts/config --disable PERSISTENT_KEYRING
scripts/config --disable EXT2
scripts/config --disable EXT3
scripts/config --disable FAT
scripts/config --disable MSDOS_FS
scripts/config --disable VFAT
scripts/config --disable EXFAT_FS
scripts/config --disable ISO9660
scripts/config --disable JFS
scripts/config --disable XFS
scripts/config --disable REISERFS_FS
scripts/config --disable NFS
scripts/config --disable CIFS
scripts/config --disable SMB_FS
scripts/config --disable 9P
scripts/config --disable IA32_AOUT
scripts/config --disable AOUT
scripts/config --disable KSM
scripts/config --disable SYSVIPC
scripts/config --disable AFS_FS
scripts/config --disable MODULES
scripts/config --disable BSD_PROCESS_ACCT
scripts/config --disable FANOTIFY
scripts/config --disable SECURITY_LANDLOCK
scripts/config --disable CROSS_MEMORY_ATTACH
scripts/config --disable IO_URING

# -----------------------------
# FINALIZE CONFIG
# -----------------------------
echo "==> Re-running olddefconfig to finalize"
make olddefconfig

# ===============================================
# BUILD + INSTALL
# ===============================================
echo "==> Building kernel..."
make -j"$(nproc)"

echo "==> Installing modules..."
sudo make modules_install

echo "==> Installing kernel..."
sudo make install

# ===============================================
# GENERATE MOK KEYS (PEM + DER)
# ===============================================
echo "==> Preparing MOK keypair..."
mkdir -p "$MOK_DIR"

if [ ! -f "$MOK_PEM" ]; then
  openssl req -new -x509 -newkey rsa:4096 -sha256 -days 3650 \
    -nodes -subj "/CN=Chris MOK/" \
    -keyout "$MOK_KEY" -out "$MOK_PEM"

  # DER format for mokutil enrollment
  openssl x509 -in "$MOK_PEM" -outform DER -out "$MOK_DER"

  echo "✅ MOK keypair created in $MOK_DIR"
else
  echo "✅ MOK keypair already exists, skipping generation"
fi

# ===============================================
# SIGN KERNEL + MODULES
# ===============================================
echo "==> Signing kernel modules..."
for mod in $(find /lib/modules/$(uname -r)/ -type f -name "*.ko"); do
  echo "  - Signing $mod"
  sudo /usr/src/linux-headers-$(uname -r)/scripts/sign-file sha512 "$MOK_KEY" "$MOK_PEM" "$mod"
done

# Sign vmlinuz
KERNEL_IMG=$(ls /boot/vmlinuz-* | grep "${KERNEL_VER}" | head -n1 || true)
if [ -n "$KERNEL_IMG" ]; then
  echo "==> Signing kernel image $KERNEL_IMG"
  sudo sbsign --key "$MOK_KEY" --cert "$MOK_PEM" --output "${KERNEL_IMG}.signed" "$KERNEL_IMG"
  sudo mv "${KERNEL_IMG}.signed" "$KERNEL_IMG"
fi

# ===============================================
# GRUB UPDATE (UEFI-aware)
# ===============================================
echo "==> Updating GRUB..."
sudo grub-mkconfig -o /boot/grub/grub.cfg

if ! grep -q "${KERNEL_VER}" /boot/grub/grub.cfg; then
    echo "⚠️ Kernel v${KERNEL_VER} not found in GRUB config, adding manual UEFI entry..."

    # Detect root partition UUID
    ROOT_UUID=$(findmnt -no UUID /)

    sudo tee -a /etc/grub.d/40_custom <<EOF

menuentry "Zen Kernel ${KERNEL_VER} (UEFI)" {
    linux /vmlinuz-${KERNEL_VER} root=UUID=${ROOT_UUID} rw quiet
    initrd /initramfs-${KERNEL_VER}.img
}
EOF

    sudo chmod +x /etc/grub.d/40_custom
    sudo grub-mkconfig -o /boot/grub/grub.cfg

    echo "✅ Manual GRUB entry added for v${KERNEL_VER}"
fi

# ===============================================
# SYSCTL Hardening (commented out)
# ===============================================
echo "==> Applying sysctl hardening (commented out)"
sudo mkdir -p /etc/sysctl.d
cat <<EOF | sudo tee /etc/sysctl.d/99-hardening.conf
kernel.yama.ptrace_scope=2
#kernel.kptr_restrict=2
kernel.dmesg_restrict=1
fs.suid_dumpable=0
EOF

# ===============================================
# ENROLL MOK
# ===============================================
echo "==> Enrolling MOK (you will set a password and confirm at reboot)..."
#sudo mokutil --import "$MOK_DER"

echo "✅ Hardened kernel v${KERNEL_VER} installed, signed with MOK."
echo "⚠️ Reboot, select 'Enroll MOK' in the blue MokManager screen, and enter your password."
