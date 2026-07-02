#!/bin/bash
# Engrampa AppImage 构建脚本
# 修复: 手动复制 GTK 库，避免 patchelf 损坏 .gresource.gtk 段
set -euo pipefail

SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILDDIR="$SRCDIR/builddir"
APPDIR="/tmp/Engrampa.AppDir"
TOOLSDIR="$SRCDIR/build-tools"
OUTPUT="$SRCDIR/Engrampa-x86_64.AppImage"

# 设置代理（根据需要调整）
export https_proxy="${https_proxy:-http://localhost:7890}"
export APPIMAGE_EXTRACT_AND_RUN=1

echo "==> 1. 编译 engrampa"
cd "$SRCDIR"
meson setup "$BUILDDIR" --prefix=/usr --buildtype=release \
  -Dmagic=true -Dcaja-actions=true -Dpackagekit=false 2>&1 | tail -3
ninja -C "$BUILDDIR" 2>&1 | tail -3

echo "==> 2. 安装到 AppDir"
rm -rf "$APPDIR"
DESTDIR="$APPDIR" ninja -C "$BUILDDIR" install 2>&1 | tail -3

echo "==> 3. 编译 GSettings 模式"
glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas/"

# 复制 GTK 主题
mkdir -p "$APPDIR/usr/share/themes"
cp -a /usr/share/themes/Adwaita "$APPDIR/usr/share/themes/"
rm -rf "$APPDIR/usr/share/themes/Adwaita/gtk-2.0"

# 补全图标主题索引
cp /usr/share/icons/hicolor/index.theme "$APPDIR/usr/share/icons/hicolor/"

echo "==> 4. 下载运行时（如果不存在）"
RUNTIME="/tmp/runtime-x86_64"
if [ ! -f "$RUNTIME" ]; then
  echo "   下载 runtime ..."
  curl -sSL "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64" -o "$RUNTIME"
fi

echo "==> 5. linuxdeploy: 打包非 GTK 依赖库"
"$TOOLSDIR/linuxdeploy.AppImage" \
  --appdir "$APPDIR" \
  --desktop-file "$APPDIR/usr/share/applications/engrampa.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/engrampa.svg" \
  --plugin gtk 2>&1 | tail -5

echo "==> 6. 替换被 patchelf 损坏的库（用系统原版）"
REPLACE_LIBS=(
  libgtk-3.so.0 libgdk-3.so.0 libgdk_pixbuf-2.0.so.0
  libgio-2.0.so.0 libglib-2.0.so.0 libgobject-2.0.so.0
  libgmodule-2.0.so.0 libFcitx5GClient.so.2
)
for lib in "${REPLACE_LIBS[@]}"; do
  sys_lib="$(realpath "/usr/lib64/$lib" 2>/dev/null || true)"
  [ -z "$sys_lib" ] && continue
  bundled="$APPDIR/usr/lib/$lib"
  rm -f "$bundled" 2>/dev/null
  cp -L "$sys_lib" "$bundled"
  echo "   替换 $lib"
done

echo "==> 7. 修复输入法模块与缓存"
IMMODULES="$APPDIR/usr/lib/gtk-3.0/3.0.0/immodules"
# 用系统原版 im-fcitx5.so（无 RPATH，不依赖 patchelf）
rm -f "$IMMODULES/im-fcitx5.so" 2>/dev/null
cp /usr/lib64/gtk-3.0/3.0.0/immodules/im-fcitx5.so "$IMMODULES/im-fcitx5.so"
echo "   替换 im-fcitx5.so（系统原版，无 RPATH）"
# 在 AppRun hook 添加 LD_LIBRARY_PATH（无 RPATH 模块通过它找到 libFcitx5GClient）
HOOKFILE="$APPDIR/apprun-hooks/linuxdeploy-plugin-gtk.sh"
sed -i '/^export GTK_IM_MODULE=fcitx/d' "$HOOKFILE" 2>/dev/null || true
sed -i '/^export LD_LIBRARY_PATH/d' "$HOOKFILE" 2>/dev/null || true
sed -i '/^export GDK_PIXBUF_MODULE_FILE/a export LD_LIBRARY_PATH="$APPDIR\/usr\/lib:$LD_LIBRARY_PATH"' "$HOOKFILE"
echo "   已添加 LD_LIBRARY_PATH 到 hook"
# 重建 immodules.cache（用相对路径）
rm -f "$APPDIR/usr/lib/gtk-3.0/3.0.0/immodules.cache"
LD_LIBRARY_PATH="$APPDIR/usr/lib" gtk-query-immodules-3.0-64 \
  > "$APPDIR/usr/lib/gtk-3.0/3.0.0/immodules.cache" 2>/dev/null || true
sed -i 's|"/usr/lib64/gtk-3.0/3.0.0/immodules/|"|g' \
  "$APPDIR/usr/lib/gtk-3.0/3.0.0/immodules.cache"
sed -i 's|/usr/locale|/usr/share/locale|g' \
  "$APPDIR/usr/lib/gtk-3.0/3.0.0/immodules.cache"
# 重建 gdk-pixbuf loaders.cache（用相对路径）
rm -f "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
LD_LIBRARY_PATH="$APPDIR/usr/lib" gdk-pixbuf-query-loaders \
  > "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" 2>/dev/null || true
sed -i 's|"/usr/lib64/gdk-pixbuf-2.0/2.10.0/loaders/|"|g' \
  "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
sed -i 's|"/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/|"|g' \
  "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
sed -i 's|"/home/linuxbrew/[^"]*/gdk-pixbuf-2.0/2.10.0/loaders/|"|g' \
  "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"

echo "==> 8. 下载 appimagetool（如果不存在）"
APPIMAGETOOL="/tmp/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
  echo "   下载 appimagetool ..."
  curl -sSL "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" -o "$APPIMAGETOOL"
  chmod +x "$APPIMAGETOOL"
fi

echo "==> 9. appimagetool: 生成 AppImage"
"$APPIMAGETOOL" \
  --runtime-file "$RUNTIME" \
  --no-appstream \
  "$APPDIR" "$OUTPUT"

echo "==> 完成: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
