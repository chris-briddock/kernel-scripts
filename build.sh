#!/usr/bin/env bash
# =============================================================================
# build-kernel-rpms.sh
# Compile the Linux kernel and produce kernel + kernel-headers RPMs.
# Designed for Fedora Silverblue (immutable host) — build runs inside a
# Toolbox container so no packages are ever layered onto the host OS.
#
# Usage:
#   ./build-kernel-rpms.sh [OPTIONS]
#
# Options:
#   -v, --version <ver>    Kernel version to fetch  (e.g. 6.9.3)
#                          Omit to use the source in --src-dir.
#   -s, --src-dir <path>   Path to an existing kernel source tree.
#                          Ignored when --version is supplied.
#   -c, --config <mode>    Config mode: existing | current | menuconfig | defconfig
#                            existing   – use .config already in the source tree
#                            current    – copy /boot/config-$(uname -r) (default)
#                            menuconfig – interactive TUI config editor
#                            defconfig  – architecture default config
#   -j, --jobs <n>         Parallel build jobs  (default: nproc)
#   -o, --output <dir>     Where to copy the final RPMs  (default: ~/kernel-rpms)
#   -b, --box-name <name>  Toolbox container name  (default: kernel-builder)
#   -f, --fedora <ver>     Fedora release for the toolbox  (default: same as host)
#       --localversion <s> Append string to kernel version  (e.g. -custom)
#       --skip-fetch       Skip downloading source; use --src-dir as-is
#       --no-cleanup       Keep source tree after build (useful for iteration)
#   -h, --help             Show this help message
#
# Requirements (host):
#   toolbox   – ships with Fedora Silverblue
#   curl      – for downloading kernel tarballs
#   tar       – for extracting tarballs
#
# All compilation dependencies are installed automatically inside the toolbox.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

# Calculate safe parallel jobs: cap by both CPU count and available RAM.
# Kernel linking (vmlinux.o) can consume 4–8 GB; we budget ~2 GB per job.
calc_jobs() {
    local cpu_jobs mem_kb mem_jobs
    cpu_jobs="$(nproc)"
    mem_kb="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)"
    mem_jobs=$((mem_kb / 1024 / 500))       # 500 MB per job
    [[ "$mem_jobs" -lt 1 ]] && mem_jobs=1
    [[ "$mem_jobs" -gt "$cpu_jobs" ]] && mem_jobs="$cpu_jobs"
    echo "$mem_jobs"
}

KERNEL_VERSION=""
SRC_DIR=""
CONFIG_MODE="current"
JOBS="$(calc_jobs)"
OUTPUT_DIR="${HOME}/kernel-rpms"
BOX_NAME="kernel-builder"
FEDORA_RELEASE=""
LOCAL_VERSION=""
SKIP_FETCH=false
NO_CLEANUP=false

MOK_DIR="${HOME}/.mok"
MOK_KEY="${MOK_DIR}/MOK.key"
MOK_PEM="${MOK_DIR}/MOK.pem"
MOK_DER="${MOK_DIR}/MOK.der"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

log()  { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }
warn() { echo -e "${YLW}[WARN]${RST}  $*"; }
err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; }
die()  { err "$*"; exit 1; }
banner() {
    echo -e "\n${BLD}${CYN}══════════════════════════════════════════════════${RST}"
    echo -e "${BLD}${CYN}  $*${RST}"
    echo -e "${BLD}${CYN}══════════════════════════════════════════════════${RST}\n"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^# =/p' "$0" | sed 's/^# \?//'
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)      KERNEL_VERSION="$2"; shift 2 ;;
        -s|--src-dir)      SRC_DIR="$2";        shift 2 ;;
        -c|--config)       CONFIG_MODE="$2";    shift 2 ;;
        -j|--jobs)         JOBS="$2";           shift 2 ;;
        -o|--output)       OUTPUT_DIR="$2";     shift 2 ;;
        -b|--box-name)     BOX_NAME="$2";       shift 2 ;;
        -f|--fedora)       FEDORA_RELEASE="$2"; shift 2 ;;
        --localversion)    LOCAL_VERSION="$2";  shift 2 ;;
        --skip-fetch)      SKIP_FETCH=true;     shift   ;;
        --no-cleanup)      NO_CLEANUP=true;     shift   ;;
        -h|--help)         usage ;;
        *) die "Unknown option: $1.  Run with --help for usage." ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------
if [[ -z "${KERNEL_VERSION}" && -z "${SRC_DIR}" ]]; then
    die "Provide either --version <x.y.z> or --src-dir <path>.  See --help."
fi

if [[ -n "${KERNEL_VERSION}" && -n "${SRC_DIR}" && "${SKIP_FETCH}" == "false" ]]; then
    warn "--version and --src-dir both supplied; --version takes precedence (source will be downloaded)."
    SRC_DIR=""
fi

case "${CONFIG_MODE}" in
    existing|current|menuconfig|defconfig) ;;
    *) die "Invalid --config mode '${CONFIG_MODE}'.  Choose: existing|current|menuconfig|defconfig" ;;
esac

# ---------------------------------------------------------------------------
# Detect environment
# ---------------------------------------------------------------------------
if ! command -v toolbox &>/dev/null; then
    die "'toolbox' not found.  This script is designed for Fedora Silverblue."
fi

# Detect host Fedora release for the toolbox image if not specified
if [[ -z "${FEDORA_RELEASE}" ]]; then
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        FEDORA_RELEASE="${VERSION_ID:-40}"
    else
        FEDORA_RELEASE="40"
        warn "Could not detect Fedora release; defaulting to ${FEDORA_RELEASE}."
    fi
fi

# Where we stage the build on the host (bind-mounted into toolbox automatically)
BUILD_STAGE="${HOME}/.cache/kernel-build"
mkdir -p "${BUILD_STAGE}" "${OUTPUT_DIR}"

# Derive a source directory path if downloading
if [[ -n "${KERNEL_VERSION}" ]]; then
    # Strip leading 'v' if user passed it
    KERNEL_VERSION="${KERNEL_VERSION#v}"
    SRC_DIR="${BUILD_STAGE}/linux-${KERNEL_VERSION}"
fi

# ---------------------------------------------------------------------------
# Helper: run a command inside the toolbox
# ---------------------------------------------------------------------------
box_run() {
    toolbox run --container "${BOX_NAME}" -- bash -c "$*"
}

# ---------------------------------------------------------------------------
# Step 1 – Ensure toolbox container exists
# ---------------------------------------------------------------------------
banner "Step 1 · Toolbox container"

if toolbox list 2>/dev/null | awk 'NR>1 {print $2}' | grep -q "^${BOX_NAME}$"; then
    ok "Container '${BOX_NAME}' already exists."
else
    log "Creating toolbox container '${BOX_NAME}' (Fedora ${FEDORA_RELEASE})…"
    toolbox create --container "${BOX_NAME}" --image "registry.fedoraproject.org/fedora-toolbox:${FEDORA_RELEASE}"
    ok "Container created."
fi

# ---------------------------------------------------------------------------
# Step 2 – Install build dependencies inside the toolbox
# ---------------------------------------------------------------------------
banner "Step 2 · Build dependencies"

BUILD_DEPS=(
    # Core build tools
    gcc gcc-c++ make bison flex bc
    # RPM packaging
    rpm-build rpmlint
    # Kernel-specific headers / libs
    openssl-devel elfutils-libelf-devel elfutils-devel dwarves
    # Module signing / cert tools
    openssl perl sbsigntools
    # Compression
    xz zstd
    # Python (scripts used by kbuild)
    python3
    # ncurses (menuconfig)
    ncurses-devel
    # pahole (BTF generation)
    dwarves
    # Misc kbuild deps
    binutils diffutils findutils gawk grep patch sed tar which
    # Documentation toolchain (optional but avoids warnings)
    perl-ExtUtils-MakeMaker
)

log "Installing build dependencies (this may take a moment on first run)…"
box_run "sudo dnf install -y ${BUILD_DEPS[*]} 2>&1 | tail -5"
ok "Dependencies ready."

# ---------------------------------------------------------------------------
# Step 3 – Fetch kernel source (if needed)
# ---------------------------------------------------------------------------
banner "Step 3 · Kernel source"

if [[ "${SKIP_FETCH}" == "false" && -n "${KERNEL_VERSION}" ]]; then
    TARBALL="${BUILD_STAGE}/linux-${KERNEL_VERSION}.tar.xz"
    SIG_FILE="${TARBALL}.sign"

    # Derive major version for kernel.org URL  (e.g. 6.9.3 → 6.x)
    MAJOR="${KERNEL_VERSION%%.*}"
    TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${KERNEL_VERSION}.tar.xz"
    SIG_URL="${TARBALL_URL}.sign"

    if [[ -f "${TARBALL}" ]]; then
        log "Tarball already cached at ${TARBALL}; skipping download."
    else
        log "Downloading linux-${KERNEL_VERSION} from kernel.org…"
        curl -# -L --retry 3 -o "${TARBALL}" "${TARBALL_URL}"
        curl -# -L --retry 3 -o "${SIG_FILE}" "${SIG_URL}" 2>/dev/null || warn "Could not download PGP signature; skipping verification."
        ok "Download complete."
    fi

    if [[ -d "${SRC_DIR}" ]]; then
        log "Source directory ${SRC_DIR} already exists; skipping extraction."
    else
        log "Extracting tarball…"
        tar -xf "${TARBALL}" -C "${BUILD_STAGE}"
        ok "Source extracted to ${SRC_DIR}."
    fi
elif [[ -n "${SRC_DIR}" ]]; then
    [[ -d "${SRC_DIR}" ]] || die "Source directory '${SRC_DIR}' does not exist."
    ok "Using existing source at ${SRC_DIR}."
fi

# Confirm the source tree looks sane
[[ -f "${SRC_DIR}/Makefile" ]] || die "No Makefile found in ${SRC_DIR}; not a valid kernel source tree."

# ---------------------------------------------------------------------------
# Step 4 – Kernel configuration
# ---------------------------------------------------------------------------
banner "Step 4 · Kernel configuration"

case "${CONFIG_MODE}" in
    current)
        # On Silverblue (and most modern Fedora), the running kernel's config is
        # stored in /lib/modules/<ver>/config rather than /boot/config-<ver>.
        # Check both locations; the host path is accessible directly (no box_run needed).
        KVER="$(uname -r)"
        BOOT_CONFIG_MODULES="/lib/modules/${KVER}/config"
        BOOT_CONFIG_BOOT="/boot/config-${KVER}"
        if [[ -f "${BOOT_CONFIG_MODULES}" ]]; then
            BOOT_CONFIG="${BOOT_CONFIG_MODULES}"
        elif [[ -f "${BOOT_CONFIG_BOOT}" ]]; then
            BOOT_CONFIG="${BOOT_CONFIG_BOOT}"
        else
            BOOT_CONFIG=""
        fi

        if [[ -n "${BOOT_CONFIG}" ]]; then
            log "Copying current kernel config from ${BOOT_CONFIG}…"
            cp "${BOOT_CONFIG}" "${SRC_DIR}/.config"
            # Resolve any new Kconfig symbols introduced since this config was made
            log "Running 'make olddefconfig' to accept new symbols with defaults…"
            box_run "cd '${SRC_DIR}' && make olddefconfig"
        else
            warn "Could not find a config for kernel ${KVER} in /lib/modules or /boot; falling back to defconfig."
            box_run "cd '${SRC_DIR}' && make defconfig"
        fi
        ;;
    existing)
        [[ -f "${SRC_DIR}/.config" ]] || die "No .config found in ${SRC_DIR}.  Use --config current or defconfig."
        log "Using existing .config in source tree."
        box_run "cd '${SRC_DIR}' && make olddefconfig"
        ;;
    menuconfig)
        log "Launching menuconfig (interactive)…"
        # Need to run this in the current terminal with a TTY
        toolbox run --container "${BOX_NAME}" -- bash -c "cd '${SRC_DIR}' && make menuconfig"
        ;;
    defconfig)
        log "Generating architecture default config…"
        box_run "cd '${SRC_DIR}' && make defconfig"
        ;;
esac

# -----------------------------
# HARDENING FLAGS
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Applying hardening flags...' && \
  scripts/config --enable STACKPROTECTOR_STRONG && \
  scripts/config --enable FORTIFY_SOURCE && \
  scripts/config --enable REFCOUNT_FULL && \
  scripts/config --enable GCC_PLUGIN_RANDSTRUCT && \
  scripts/config --enable GCC_PLUGIN_STACKLEAK && \
  scripts/config --enable INIT_STACK_ALL_ZERO && \
  scripts/config --enable SECURITY && \
  scripts/config --enable SECURITY_YAMA && \
  scripts/config --enable SECURITY_YAMA_STACKED && \
  scripts/config --enable HARDENED_USERCOPY && \
  scripts/config --enable RANDOMIZE_BASE && \
  scripts/config --enable STRICT_KERNEL_RWX"

# -----------------------------
# KERNEL LOCKDOWN
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Applying kernel lockdown' && \
  scripts/config --enable LOCK_DOWN_KERNEL && \
  scripts/config --enable LOCK_DOWN_KERNEL_FORCE_INTEGRITY && \
  scripts/config --disable LOCK_DOWN_KERNEL_FORCE_NONE"

# -----------------------------
# DISABLE KEXEC / ALTERNATE KERNEL LOADING
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Disabling kernel replacement (kexec, crash dump)' && \
  scripts/config --disable KEXEC && \
  scripts/config --disable KEXEC_FILE && \
  scripts/config --disable KEXEC_SIG && \
  scripts/config --disable KEXEC_CORE && \
  scripts/config --disable CRASH_DUMP"

# -----------------------------
# DISABLE DEBUG / LEGACY FEATURES
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Disabling legacy/debug features' && \
  scripts/config --disable BINFMT_MISC && \
  scripts/config --disable LEGACY_PTYS && \
  scripts/config --disable PROC_KCORE && \
  scripts/config --disable DEV_COREDUMP && \
  scripts/config --disable DEBUG_KERNEL && \
  scripts/config --disable KALLSYMS && \
  scripts/config --disable KALLSYMS_ALL && \
  scripts/config --disable DEBUG_INFO && \
  scripts/config --disable MAGIC_SYSRQ && \
  scripts/config --disable PROC_VMCORE && \
  scripts/config --disable BUG && \
  scripts/config --disable PTRACE && \
  scripts/config --disable DEBUG_MISC && \
  scripts/config --disable PERF_EVENTS && \
  scripts/config --disable DEVKMEM && \
  scripts/config --disable DEVMEM && \
  scripts/config --disable KGDB && \
  scripts/config --disable KDB && \
  scripts/config --disable DEBUG_INFO_BTF && \
  scripts/config --disable DEBUG_INFO_REDUCED && \
  scripts/config --disable FTRACE && \
  scripts/config --disable FUNCTION_TRACER && \
  scripts/config --disable FUNCTION_GRAPH_TRACER && \
  scripts/config --disable KPROBES && \
  scripts/config --disable UPROBES && \
  scripts/config --disable BPF_SYSCALL && \
  scripts/config --disable HAVE_EBPF_JIT && \
  scripts/config --disable BPF_JIT && \
  scripts/config --disable PROC_PAGE_MONITOR && \
  scripts/config --disable USERFAULTFD && \
  scripts/config --disable KEYS && \
  scripts/config --disable PERSISTENT_KEYRING && \
  scripts/config --disable EXT2 && \
  scripts/config --disable EXT3 && \
  scripts/config --disable FAT && \
  scripts/config --disable MSDOS_FS && \
  scripts/config --disable VFAT && \
  scripts/config --disable EXFAT_FS && \
  scripts/config --disable ISO9660 && \
  scripts/config --disable JFS && \
  scripts/config --disable XFS && \
  scripts/config --disable REISERFS_FS && \
  scripts/config --disable NFS && \
  scripts/config --disable CIFS && \
  scripts/config --disable SMB_FS && \
  scripts/config --disable 9P && \
  scripts/config --disable IA32_AOUT && \
  scripts/config --disable AOUT && \
  scripts/config --disable KSM && \
  scripts/config --disable SYSVIPC && \
  scripts/config --disable AFS_FS && \
  scripts/config --disable MODULES && \
  scripts/config --disable BSD_PROCESS_ACCT && \
  scripts/config --disable FANOTIFY && \
  scripts/config --disable SECURITY_LANDLOCK && \
  scripts/config --disable CROSS_MEMORY_ATTACH && \
  scripts/config --disable IO_URING"

# -----------------------------
# DISABLE TESTS
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Disabling kernel unit tests, torture tests and self-tests' && \
  scripts/config --disable KUNIT && \
  scripts/config --disable KUNIT_DEBUGFS && \
  scripts/config --disable KUNIT_TEST && \
  scripts/config --disable KUNIT_EXAMPLE_TEST && \
  scripts/config --disable KUNIT_ALL_TESTS && \
  scripts/config --disable RCUTORTURE_TEST && \
  scripts/config --disable LOCK_TORTURE_TEST && \
  scripts/config --disable RCU_PERF_TEST && \
  scripts/config --disable RCU_SCALE_TEST && \
  scripts/config --disable WW_MUTEX_SELFTEST && \
  scripts/config --disable DEBUG_LOCKING_API_SELFTESTS && \
  scripts/config --disable PROVE_RCU && \
  scripts/config --disable TORTURE_TEST && \
  scripts/config --disable LKDTM && \
  scripts/config --disable TEST_BPF && \
  scripts/config --disable TEST_FIRMWARE && \
  scripts/config --disable TEST_KMOD && \
  scripts/config --disable TEST_LKM && \
  scripts/config --disable TEST_USER_COPY && \
  scripts/config --disable TEST_STATIC_KEYS && \
  scripts/config --disable TEST_KSTRTOX && \
  scripts/config --disable TEST_LIST_SORT && \
  scripts/config --disable TEST_SORT && \
  scripts/config --disable TEST_UUID && \
  scripts/config --disable TEST_XARRAY && \
  scripts/config --disable TEST_MAPLE_TREE && \
  scripts/config --disable TEST_RHASHTABLE && \
  scripts/config --disable TEST_IDA && \
  scripts/config --disable TEST_IDR && \
  scripts/config --disable TEST_LRU && \
  scripts/config --disable TEST_BITOPS && \
  scripts/config --disable TEST_VMALLOC && \
  scripts/config --disable TEST_FREE_PAGES && \
  scripts/config --disable TEST_FPU && \
  scripts/config --disable TEST_CLOCKSOURCE && \
  scripts/config --disable TEST_DIV64 && \
  scripts/config --disable TEST_UDELAY && \
  scripts/config --disable TEST_STATIC_KEY_BASE && \
  scripts/config --disable TEST_REF_COUNT && \
  scripts/config --disable TEST_STACKINIT && \
  scripts/config --disable TEST_MEMCAT_P && \
  scripts/config --disable TEST_OBJPOOL && \
  scripts/config --disable TEST_MEMINIT && \
  scripts/config --disable TEST_HMM && \
  scripts/config --disable TEST_IOV_ITER && \
  scripts/config --disable TEST_BLACKHOLE_DEV && \
  scripts/config --disable TEST_ASYNC_DRIVER_PROBE && \
  scripts/config --disable TEST_PRINTF && \
  scripts/config --disable TEST_SCANF && \
  scripts/config --disable TEST_BITMAP && \
  scripts/config --disable TEST_STRSCPY && \
  scripts/config --disable TEST_SYSCTL && \
  scripts/config --disable TEST_HASH && \
  scripts/config --disable TEST_PARMAN && \
  scripts/config --disable TEST_PI && \
  scripts/config --disable TEST_PLIST && \
  scripts/config --disable TEST_OVERFLOW && \
  scripts/config --disable TEST_SIPHASH && \
  scripts/config --disable TEST_HEXDUMP && \
  scripts/config --disable TEST_STRING_HELPERS && \
  scripts/config --disable TEST_MIN_HEAP && \
  scripts/config --disable TEST_SLUB && \
  scripts/config --disable TEST_DAX && \
  scripts/config --disable TEST_LIVEPATCH && \
  scripts/config --disable TEST_DHRY && \
  scripts/config --disable TEST_NR_CPUS && \
  scripts/config --disable TEST_CORESIGHT && \
  scripts/config --disable TEST_RSEQ && \
  scripts/config --disable TEST_VCPU_STALL_DETECTOR && \
  scripts/config --disable TEST_NVDIMM && \
  scripts/config --disable TEST_MEMCAT_P"

# -----------------------------
# DISABLE DEBUG INFRASTRUCTURE
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Disabling debug infrastructure' && \
  scripts/config --disable DEBUG_FS && \
  scripts/config --disable SLUB_DEBUG && \
  scripts/config --disable DEBUG_VM && \
  scripts/config --disable DEBUG_MEMORY_INIT && \
  scripts/config --disable DEBUG_BUGVERBOSE && \
  scripts/config --disable SCHED_DEBUG && \
  scripts/config --disable DEBUG_STACK_USAGE && \
  scripts/config --disable DEBUG_LIST && \
  scripts/config --disable DEBUG_SG && \
  scripts/config --disable DEBUG_NOTIFIERS && \
  scripts/config --disable DEBUG_CREDENTIALS && \
  scripts/config --disable PROVE_LOCKING && \
  scripts/config --disable LOCK_STAT && \
  scripts/config --disable TRACE_IRQFLAGS && \
  scripts/config --disable DEBUG_IRQFLAGS && \
  scripts/config --disable RCU_TRACE && \
  scripts/config --disable RCU_EQS_DEBUG && \
  scripts/config --disable BLK_DEBUG_FS && \
  scripts/config --disable TIMER_STATS && \
  scripts/config --disable PM_DEBUG && \
  scripts/config --disable PM_TRACE_RTC && \
  scripts/config --disable HIBERNATION"

# -----------------------------
# DISABLE RAW HARDWARE / PRIVILEGED INTERFACES
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Disabling raw hardware and privileged interfaces' && \
  scripts/config --disable DEVPORT && \
  scripts/config --disable X86_MSR && \
  scripts/config --disable X86_CPUID && \
  scripts/config --disable ACPI_CUSTOM_METHOD && \
  scripts/config --disable MODIFY_LDT_SYSCALL && \
  scripts/config --disable X86_X32_ABI && \
  scripts/config --disable IA32_EMULATION && \
  scripts/config --disable X86_16BIT && \
  scripts/config --set-val LEGACY_VSYSCALL_NONE y"

# -----------------------------
# DISABLE OTHER PRODUCTION-INAPPROPRIATE OPTIONS
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Disabling other production-inappropriate options' && \
  scripts/config --disable TRANSPARENT_HUGEPAGE && \
  scripts/config --disable UNUSED_SYMBOLS && \
  scripts/config --disable MODULE_FORCE_LOAD"

# -----------------------------
# ENABLE ADDITIONAL HARDENING
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Enabling additional hardening options' && \
  scripts/config --enable SLAB_FREELIST_RANDOM && \
  scripts/config --enable SLAB_FREELIST_HARDENED && \
  scripts/config --enable SHUFFLE_PAGE_ALLOCATOR && \
  scripts/config --enable RETPOLINE && \
  scripts/config --enable X86_KERNEL_IBT && \
  scripts/config --enable X86_USER_SHADOW_STACK && \
  scripts/config --enable STATIC_USERMODEHELPER"

# -----------------------------
# MODULE SIGNING (MOK)
# -----------------------------
box_run "cd '${SRC_DIR}' && \
  echo '==> Configuring module signing with MOK key...' && \
  scripts/config --enable MODULE_SIG && \
  scripts/config --enable MODULE_SIG_ALL && \
  scripts/config --set-str MODULE_SIG_KEY '${MOK_KEY}' && \
  scripts/config --set-str MODULE_SIG_HASH 'sha512'" 2>/dev/null || true

# Append local version string
if [[ -n "${LOCAL_VERSION}" ]]; then
    log "Setting CONFIG_LOCALVERSION to '${LOCAL_VERSION}'…"
    box_run "cd '${SRC_DIR}' && scripts/config --set-str LOCALVERSION '${LOCAL_VERSION}'"
fi

ok "Kernel configured."

# ---------------------------------------------------------------------------
# Step 4.5 – Generate MOK keypair
# ---------------------------------------------------------------------------
banner "Step 4.5 · MOK keypair"

if [[ -f "${MOK_PEM}" ]]; then
    ok "MOK keypair already exists in ${MOK_DIR}; skipping generation."
else
    log "Generating MOK keypair in ${MOK_DIR}…"
    mkdir -p "${MOK_DIR}"
    openssl req -new -x509 -newkey rsa:4096 -sha256 -days 3650 \
        -nodes -subj "/CN=Chris MOK/" \
        -keyout "${MOK_KEY}" -out "${MOK_PEM}"
    openssl x509 -in "${MOK_PEM}" -outform DER -out "${MOK_DER}"
    ok "MOK keypair created."
    warn "Enroll the DER certificate with: mokutil --import ${MOK_DER}"
fi

# ---------------------------------------------------------------------------
# Step 5 – Build and sign kernel / modules
# ---------------------------------------------------------------------------
banner "Step 5 · Building kernel  (jobs: ${JOBS})"
log "This will take a while — typical build: 20–60 min depending on hardware."
log "If the build dies with 'Error 137' during vmlinux.o linking, the system ran out of RAM."
log "The script now auto-limits jobs based on memory; you can also add swap or close other apps."

# Build kernel image and modules
box_run "cd '${SRC_DIR}' && make -j'${JOBS}'"

ok "Build complete."

# ----------------------------------------------
# Sign kernel image with MOK
# ----------------------------------------------
banner "Step 5 · Signing kernel image"

KERNEL_IMG_REL="$(box_run "cd '${SRC_DIR}' && make -s image_name")"
KERNEL_IMG="${SRC_DIR}/${KERNEL_IMG_REL}"

if [[ -f "${KERNEL_IMG}" ]]; then
    log "Signing kernel image ${KERNEL_IMG}…"
    box_run "sbsign --key '${MOK_KEY}' --cert '${MOK_PEM}' --output '${KERNEL_IMG}.signed' '${KERNEL_IMG}' && mv '${KERNEL_IMG}.signed' '${KERNEL_IMG}'"
    ok "Kernel image signed."
else
    warn "Could not locate built kernel image; skipping kernel signing."
fi

# ----------------------------------------------
# Sign kernel modules with MOK
# ----------------------------------------------
banner "Step 5 · Signing kernel modules"

cat > "${SRC_DIR}/sign-modules.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for mod in $(find . -path './arch/*/boot/*' -prune -o -name '*.ko' -print); do
    if [[ -f "$mod" ]]; then
        echo "  - Signing $mod"
        ./scripts/sign-file sha512 "$1" "$2" "$mod"
    fi
done
EOF
chmod +x "${SRC_DIR}/sign-modules.sh"

log "Signing built kernel modules…"
box_run "'${SRC_DIR}/sign-modules.sh' '${MOK_KEY}' '${MOK_PEM}'"
ok "Module signing complete."

# ----------------------------------------------
# Package signed artifacts into RPMs
# ----------------------------------------------
banner "Step 5 · Packaging RPMs"

box_run "cd '${SRC_DIR}' && make -j'${JOBS}' binrpm-pkg \
    RPMOPTS='--define \"%_binary_payload w19T8.zstdio\"' \
    2>&1"

ok "RPM packaging complete."

# ---------------------------------------------------------------------------
# Step 6 – Collect RPMs
# ---------------------------------------------------------------------------
banner "Step 6 · Collecting RPMs"

# Ensure KERNEL_VERSION is set (needed for RPM path when --src-dir was used)
if [[ -z "${KERNEL_VERSION}" ]]; then
    KERNEL_VERSION="$(box_run "cd '${SRC_DIR}' && make -s kernelversion 2>/dev/null")"
    [[ -z "${KERNEL_VERSION}" ]] && KERNEL_VERSION="unknown"
fi

RPMBUILD_DIR="$HOME/.cache/kernel-build/linux-${KERNEL_VERSION}/rpmbuild"

FOUND=0
while IFS= read -r -d '' rpm; do
    dest="${OUTPUT_DIR}/$(basename "${rpm}")"
    cp -v "${rpm}" "${dest}"
    FOUND=$((FOUND + 1))
done < <(find "${RPMBUILD_DIR}/RPMS" -name "kernel*.rpm" -print0 2>/dev/null)

if [[ "${FOUND}" -eq 0 ]]; then
    die "No kernel RPMs found in ${RPMBUILD_DIR}.  Check the build log above."
fi

ok "${FOUND} RPM(s) copied to ${OUTPUT_DIR}."
# ---------------------------------------------------------------------------
# Step 7 – Cleanup (optional)
# ---------------------------------------------------------------------------
if [[ "${NO_CLEANUP}" == "false" && -n "${KERNEL_VERSION}" ]]; then
    banner "Step 7 · Cleanup"
    log "Removing source tree ${SRC_DIR} to reclaim disk space…"
    rm -rf "${SRC_DIR}"
    log "(Tarball kept in ${BUILD_STAGE} for re-use.)"
    ok "Cleanup done."
fi

# ---------------------------------------------------------------------------
# Step 8 – MOK enrollment reminder
# ---------------------------------------------------------------------------
banner "Step 8 · MOK enrollment"

log "MOK certificate: ${MOK_DER}"
if [[ -f "${MOK_DER}" ]]; then
    warn "Enroll the MOK certificate before rebooting:"
    echo -e "  ${BLD}sudo mokutil --import ${MOK_DER}${RST}"
    echo ""
    echo -e "  ${YLW}You will set a password and confirm enrollment at the next reboot.${RST}"
    echo -e "  ${YLW}Reboot, select 'Enroll MOK' in the MokManager screen, and enter the password.${RST}"
else
    warn "MOK DER certificate not found; skipping enrollment reminder."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "Build complete 🎉"
echo -e "${BLD}RPMs are in:${RST} ${OUTPUT_DIR}"
echo ""
echo -e "${BLD}To install on Silverblue (layers onto the host — use with care):${RST}"
echo -e "  rpm-ostree install ${OUTPUT_DIR}/kernel-*.rpm"
echo ""
echo -e "${BLD}Or install inside a toolbox / VM / test machine:${RST}"
echo -e "  sudo rpm -ivh ${OUTPUT_DIR}/kernel-*.rpm"
echo ""
echo -e "${BLD}Generated RPMs:${RST}"
find "${OUTPUT_DIR}" -name "kernel*.rpm" -printf "  %f\n" | sort
echo ""
