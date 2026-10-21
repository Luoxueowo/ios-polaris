#!/bin/sh
# 由 xnu/src/bsd/dev/polaris_touch_i2c.c 重新生成 0091 补丁里的新文件段，
# 让源码目录与补丁保持一致。conf/files 与 polaris_ufs.c 的 hunk 原样保留。
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/xnu/src/bsd/dev/polaris_touch_i2c.c"
patch="$repo/xnu/patches/0091-polaris-touch-s3330.patch"

[ -f "$src" ] || { echo "缺少 $src" >&2; exit 1; }
[ -f "$patch" ] || { echo "缺少 $patch" >&2; exit 1; }

python3 - "$src" "$patch" <<'PY'
import sys

src, patch = sys.argv[1], sys.argv[2]
text = open(src, newline='').read()
lines = text.split('\n')
if lines and lines[-1] == '':
    lines.pop()

head = [
    'diff --git a/bsd/dev/polaris_touch_i2c.c b/bsd/dev/polaris_touch_i2c.c',
    'new file mode 100644',
    '--- /dev/null',
    '+++ b/bsd/dev/polaris_touch_i2c.c',
    '@@ -0,0 +1,%d @@' % len(lines),
]
head += ['+' + l for l in lines]

old = open(patch, newline='').read()
marker = 'diff --git a/bsd/conf/files'
i = old.index(marker)
open(patch, 'w', newline='').write('\n'.join(head) + '\n' + old[i:])
print('0091 新文件段已按 %d 行重新生成' % len(lines))
PY
