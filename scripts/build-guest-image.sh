#!/bin/bash
set -euo pipefail

# Builds/fetches boo_box guest VM assets into Resources/vm/:
#   - vmlinux-arm64 : Prebuilt minimal Kata Containers arm64 Linux kernel
#   - rootfs.ext4   : Minimal Alpine arm64 Linux rootfs with zsh, git, curl,
#                     python3, Ghostty 1.4.0 terminfo/shell-integration, and
#                     static /sbin/sbox-init PID 1 vsock PTY daemon.
#
# Uses Docker ONLY at image-build time. boo_box.app runs 100% natively on
# Apple Virtualization.framework with zero Docker/OrbStack dependency.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Resources/vm"
mkdir -p "$OUT_DIR"

KATA_VERSION="4.4.0"
KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-arm64.tar.zst"
KERNEL_OUT="$OUT_DIR/vmlinux-arm64"
ROOTFS_OUT="$OUT_DIR/rootfs.ext4"

# 1. Fetch arm64 Linux kernel (skip if already cached)
if [ ! -f "$KERNEL_OUT" ]; then
    echo "Fetching Kata Containers ${KATA_VERSION} arm64 Linux kernel..."
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    curl -fsSL "$KATA_URL" -o "$WORK/kata.tar.zst"
    # Extract only the container kernel (vmlinux.container or vmlinux-*)
    KERNEL_MEMBER=$(zstd -dc "$WORK/kata.tar.zst" | tar -tf - | grep -E 'share/kata-containers/vmlinux\.container$' | head -n 1 || true)
    if [ -z "$KERNEL_MEMBER" ]; then
        KERNEL_MEMBER=$(zstd -dc "$WORK/kata.tar.zst" | tar -tf - | grep -E 'share/kata-containers/vmlinux-[0-9]' | head -n 1)
    fi
    echo "Extracting kernel: $KERNEL_MEMBER"
    zstd -dc "$WORK/kata.tar.zst" | tar -xf - -C "$WORK" "$KERNEL_MEMBER"
    # Resolve symlink if vmlinux.container points to versioned vmlinux-*
    if [ -L "$WORK/$KERNEL_MEMBER" ]; then
        TARGET=$(readlink "$WORK/$KERNEL_MEMBER")
        DIR=$(dirname "$KERNEL_MEMBER")
        REAL_MEMBER="$DIR/$TARGET"
        echo "Resolving symlink -> $REAL_MEMBER"
        zstd -dc "$WORK/kata.tar.zst" | tar -xf - -C "$WORK" "$REAL_MEMBER"
        cp "$WORK/$REAL_MEMBER" "$KERNEL_OUT"
    else
        cp "$WORK/$KERNEL_MEMBER" "$KERNEL_OUT"
    fi
    rm -rf "$WORK"
    trap - EXIT
    echo "Kernel ready: $KERNEL_OUT ($(du -h "$KERNEL_OUT" | cut -f1))"
else
    echo "Kernel cached: $KERNEL_OUT"
fi

# 2. Build minimal Alpine arm64 rootfs.ext4 + static sbox-init via build container
echo "Building Alpine arm64 rootfs.ext4 + static /sbin/sbox-init..."

GHOSTTY_RES="/Applications/Ghostty.app/Contents/Resources"
MOUNT_GHOSTTY=""
if [ -d "$GHOSTTY_RES/terminfo" ] && [ -d "$GHOSTTY_RES/ghostty" ]; then
    MOUNT_GHOSTTY="-v ${GHOSTTY_RES}:/ghostty-res:ro"
fi

docker run --rm --platform linux/arm64 \
    -v "$ROOT/guest:/src:ro" \
    -v "$OUT_DIR:/out" \
    $MOUNT_GHOSTTY \
    alpine:3.21 sh -eux -c '
apk add --no-cache gcc musl-dev linux-headers e2fsprogs

# Compile tiny static PID 1 vsock PTY daemon
gcc -static -O2 -Wall -Wextra -o /tmp/sbox-init /src/sbox-init.c
strip /tmp/sbox-init

# Assemble clean minimal guest rootfs in /tmp/rootfs
ROOTFS=/tmp/rootfs
mkdir -p "$ROOTFS"
apk --root "$ROOTFS" --initdb --no-cache \
    --repositories-file /etc/apk/repositories \
    --keys-dir /etc/apk/keys \
    add alpine-baselayout alpine-keys apk-tools busybox \
        zsh bash git curl ca-certificates coreutils \
        ncurses-terminfo-base ncurses-terminfo less jq ripgrep \
        python3 vim iproute2

install -m 0755 /tmp/sbox-init "$ROOTFS/sbin/sbox-init"
mkdir -p "$ROOTFS/root" "$ROOTFS/workspace" "$ROOTFS/tmp" "$ROOTFS/run" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev/pts"

# Basic /etc files
echo "boobox" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1 localhost boobox
::1       localhost boobox
EOF
cat > "$ROOTFS/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Install Ghostty 1.4.0 terminfo & shell-integration into Linux single-letter terminfo dirs
if [ -d /ghostty-res/terminfo ]; then
    mkdir -p "$ROOTFS/usr/share/terminfo/x" "$ROOTFS/usr/share/terminfo/g" \
             "$ROOTFS/etc/terminfo/x" "$ROOTFS/etc/terminfo/g"
    if [ -f /ghostty-res/terminfo/78/xterm-ghostty ]; then
        cp /ghostty-res/terminfo/78/xterm-ghostty "$ROOTFS/usr/share/terminfo/x/xterm-ghostty"
        cp /ghostty-res/terminfo/78/xterm-ghostty "$ROOTFS/etc/terminfo/x/xterm-ghostty"
    fi
    if [ -f /ghostty-res/terminfo/67/ghostty ]; then
        cp /ghostty-res/terminfo/67/ghostty "$ROOTFS/usr/share/terminfo/g/ghostty"
        cp /ghostty-res/terminfo/67/ghostty "$ROOTFS/etc/terminfo/g/ghostty"
    fi
fi
if [ -d /ghostty-res/ghostty ]; then
    mkdir -p "$ROOTFS/etc/ghostty"
    cp -R /ghostty-res/ghostty/shell-integration "$ROOTFS/etc/ghostty/"
fi

# Clean default zshrc with OSC 7 pwd reporting + Ghostty integration + crisp prompt
cat > "$ROOTFS/root/.zshrc" <<'\''ZSHRC'\''
export TERM="${TERM:-xterm-ghostty}"
export GHOSTTY_RESOURCES_DIR="/etc/ghostty"
if [ -f /etc/ghostty/shell-integration/zsh/ghostty-integration ]; then
    source /etc/ghostty/shell-integration/zsh/ghostty-integration
fi

# Emit OSC 7 pwd on every prompt so boo_box sidebar tracks directory cleanly
_boobox_precmd() {
    printf "\e]7;file://boobox%s\a" "$PWD"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _boobox_precmd
PROMPT="%F{cyan}boobox%f %F{blue}%~%f %# "
HISTFILE=/root/.zsh_history
HISTSIZE=5000
SAVEHIST=5000
alias ll="ls -la"
ZSHRC

# Make root login shell zsh
sed -i "s|^root:.*:/bin/sh$|root:x:0:0:root:/root:/bin/zsh|" "$ROOTFS/etc/passwd" || true

# Build 2 GiB sparse ext4 image from directory (no loop mount required)
rm -f /out/rootfs.ext4.tmp
truncate -s 2G /out/rootfs.ext4.tmp
mke2fs -q -t ext4 -L boobox-root -d "$ROOTFS" /out/rootfs.ext4.tmp
mv /out/rootfs.ext4.tmp /out/rootfs.ext4
ls -lh /out/rootfs.ext4
'

echo "Guest assets ready in $OUT_DIR:"
ls -lh "$OUT_DIR"
