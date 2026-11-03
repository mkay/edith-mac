#!/usr/bin/env bash
# Build libssh2 on a static OpenSSL as a universal (arm64 + x86_64)
# CLibssh2.xcframework for EdithCore. The result is not checked in; run this
# once after cloning, or after changing a version below.
set -euo pipefail

OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
LIBSSH2_VERSION="1.11.1"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
MIN_MACOS="15.0"
ARCHS=(arm64 x86_64)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/deps"
OUT="$ROOT/Packages/EdithCore/Vendor/CLibssh2.xcframework"
JOBS="$(sysctl -n hw.ncpu)"

if [ -d "$OUT" ] && [ "${1:-}" != "--force" ]; then
    echo "$OUT exists — pass --force to rebuild."
    exit 0
fi

rm -rf "$WORK"
mkdir -p "$WORK/src"

# fetch <url> <sha256>: download into $WORK/src and verify, or fail.
fetch() {
    local file="$WORK/src/$(basename "$1")"
    echo "Downloading $(basename "$1")…"
    curl -fsSL "$1" -o "$file"
    echo "$2  $file" | shasum -a 256 -c --status || { echo "checksum mismatch: $file" >&2; exit 1; }
}
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
fetch "https://libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz" "$LIBSSH2_SHA256"

for arch in "${ARCHS[@]}"; do
    prefix="$WORK/$arch"
    flags="-arch $arch -mmacosx-version-min=$MIN_MACOS"

    echo "Building OpenSSL ($arch)…"
    rm -rf "$WORK/openssl-$arch" && mkdir "$WORK/openssl-$arch"
    tar -xzf "$WORK/src/openssl-$OPENSSL_VERSION.tar.gz" -C "$WORK/openssl-$arch" --strip-components 1
    (
        cd "$WORK/openssl-$arch"
        target=$([ "$arch" = arm64 ] && echo darwin64-arm64-cc || echo darwin64-x86_64-cc)
        ./Configure "$target" no-shared no-tests no-apps no-docs no-engine no-module \
            --prefix="$prefix" --libdir=lib -mmacosx-version-min=$MIN_MACOS >/dev/null
        make -j"$JOBS" build_libs >/dev/null
        make install_dev >/dev/null
    )

    echo "Building libssh2 ($arch)…"
    rm -rf "$WORK/libssh2-$arch" && mkdir "$WORK/libssh2-$arch"
    tar -xzf "$WORK/src/libssh2-$LIBSSH2_VERSION.tar.gz" -C "$WORK/libssh2-$arch" --strip-components 1
    (
        cd "$WORK/libssh2-$arch"
        host=$([ "$arch" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
        CFLAGS="$flags -O2" LDFLAGS="$flags" ./configure --host="$host" --prefix="$prefix" \
            --with-crypto=openssl --with-libssl-prefix="$prefix" \
            --disable-shared --enable-static --without-libz \
            --disable-examples-build --disable-docker-tests --disable-sshd-tests >/dev/null
        make -j"$JOBS" -C src >/dev/null
        make -C src install >/dev/null
        make install-includeHEADERS >/dev/null
    )

    # One static library holding libssh2 and the OpenSSL it needs.
    libtool -static -o "$prefix/libCLibssh2.a" \
        "$prefix/lib/libssh2.a" "$prefix/lib/libssl.a" "$prefix/lib/libcrypto.a" 2>/dev/null
done

echo "Assembling xcframework…"
universal="$WORK/universal"
mkdir -p "$universal/Headers"
lipo -create $(for a in "${ARCHS[@]}"; do echo "$WORK/$a/libCLibssh2.a"; done) -output "$universal/libCLibssh2.a"
cp "$WORK/${ARCHS[0]}"/include/libssh2*.h "$universal/Headers/"
# OpenSSL's headers too: EdithCore uses its scrypt to read the Linux app's
# encrypted password exports. The installed headers are identical for both
# architectures, so one copy serves.
cp -R "$WORK/${ARCHS[0]}/include/openssl" "$universal/Headers/"
cat > "$universal/Headers/module.modulemap" <<'EOF'
module CLibssh2 {
    header "libssh2.h"
    header "libssh2_sftp.h"
    header "libssh2_publickey.h"
    header "openssl/evp.h"
    header "openssl/kdf.h"
    export *
}
EOF

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework -library "$universal/libCLibssh2.a" -headers "$universal/Headers" -output "$OUT" >/dev/null
echo "Done — $OUT ($(lipo -archs "$universal/libCLibssh2.a"))"
