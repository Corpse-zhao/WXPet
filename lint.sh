#!/usr/bin/env bash
# ============================================================
#  悬浮宠物 WXPet 本地静态预检
#
#  用途：推送前在 Windows 上自查，把 CI 会拦的低级错误提前抓出来。
#  不编译，只做静态断言 —— 秒级完成。
#
#  用法：bash lint.sh
# ============================================================
set -uo pipefail

PASS=0
FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

PY=""
if command -v python3 >/dev/null 2>&1; then PY=$(command -v python3)
elif command -v python >/dev/null 2>&1; then PY=$(command -v python)
fi

echo "═══ WXPet 静态预检 ═══"
echo ""

# ── 1. 打包方案 ──────────────────────────────────────────────
echo "[1/16] 打包方案（roothide 隐根）"
if grep -q 'THEOS_PACKAGE_SCHEME = roothide' Makefile 2>/dev/null; then
    ok "Makefile: THEOS_PACKAGE_SCHEME = roothide"
else
    bad "Makefile 缺 THEOS_PACKAGE_SCHEME = roothide（rootless 的包会被 Sileo 拒装）"
fi
if grep -q '^Architecture: iphoneos-arm64e' control 2>/dev/null; then
    ok "control: Architecture = iphoneos-arm64e"
else
    bad "control: Architecture 必须是 iphoneos-arm64e（当前：$(grep '^Architecture:' control 2>/dev/null | awk '{print $2}')）"
fi
if grep -q 'ARCHS = arm64 arm64e' Makefile 2>/dev/null; then
    ok "Makefile: ARCHS = arm64 arm64e"
else
    bad "Makefile: 必须 ARCHS = arm64 arm64e"
fi

# ── 2. ⭐⭐ 注入清单只允许 SpringBoard ────────────────────────
# 这是本项目的**架构底线**：一旦往清单里加了微信，方案就从
# 「零风险装饰层」变成「逆向第三方 App」，收益为 0、风险极大。
echo ""
echo "[2/16] ⭐ 注入清单只允许 SpringBoard"
if grep -q 'com.apple.springboard' WXPet.plist 2>/dev/null; then
    ok "filter plist 含 com.apple.springboard"
else
    bad "filter plist 缺 com.apple.springboard"
fi
if grep -Eqi 'tencent|wechat|wetype|weixin' WXPet.plist 2>/dev/null; then
    bad "filter plist 里出现了目标 App（微信/输入法）—— 架构底线被破坏！"
    bad "  本插件靠 SpringBoard 的窗口层级盖住目标 App，绝不需要注入它。"
else
    ok "filter plist 未包含任何目标 App"
fi
if grep -q '<key>Executables</key>' WXPet.plist 2>/dev/null; then
    bad "filter plist 出现了 Executables 段 —— 本插件只需要 SpringBoard，不需要按进程名注入"
else
    ok "filter plist 没有多余的 Executables 段"
fi

# ── 3. ⭐⭐ 禁止抢 key window ────────────────────────────────
echo ""
echo "[3/16] ⭐ 禁止 makeKeyAndVisible（抢系统 key window）"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys
bad = False
for path in ["WXPetWindow.m", "WXPetManager.m"]:
    src = io.open(path, encoding="utf-8", errors="replace").read()
    # 剥注释与字符串，避免文案里的同名词误报
    t = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    t = re.sub(r'//[^\n]*', '', t)
    t = re.sub(r'"(?:\\.|[^"\\])*"', '""', t)
    if "makeKeyAndVisible" in t or "makeKeyWindow" in t:
        print("  ❌ %s 里出现了 makeKeyAndVisible / makeKeyWindow" % path)
        print("     血泪：自建高层级窗口抢走 key window 后，下层界面会「看得见但点不动」。")
        print("     正解：hidden = NO + 够高的 windowLevel，根本不需要当 key window。")
        bad = True
if not bad:
    print("  ✅ 自建窗口未抢 key window")
sys.exit(1 if bad else 0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查（请在 CI 里确认）"
fi

# ── 4. ⭐⭐ 触摸穿透 ─────────────────────────────────────────
echo ""
echo "[4/16] ⭐ hitTest 必须放行宠物区域之外的触摸"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys
src = io.open("WXPetWindow.m", encoding="utf-8", errors="replace").read()
t = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
t = re.sub(r'//[^\n]*', '', t)
if "hitTest:(CGPoint)point withEvent:(UIEvent *)event" not in t:
    print("  ❌ WXPetWindow.m 没有重写 hitTest:withEvent:")
    sys.exit(1)
m = re.search(r'-\s*\(UIView \*\)hitTest:.*?\n\}', t, re.S)
if not m:
    print("  ❌ hitTest 方法体解析失败")
    sys.exit(1)
body = m.group(0)
if "return nil" not in body:
    print("  ❌ hitTest 里没有 return nil —— 铺满全屏的窗口会把下层 App 的点击全吃掉")
    sys.exit(1)
if "CGRectContainsPoint" not in body:
    print("  ❌ hitTest 里没有按宠物区域做判断（只可能全屏吃触摸）")
    sys.exit(1)
print("  ✅ hitTest 已按宠物区域放行触摸")
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查"
fi

# ── 5. ⭐ windowScene 必须挂 ─────────────────────────────────
echo ""
echo "[5/16] ⭐ 窗口必须挂到 windowScene（iOS 13+ 不挂就不显示）"
if grep -q 'windowScene = best' WXPetWindow.m 2>/dev/null; then
    ok "WXPetWindow.m 会设置 windowScene"
else
    bad "缺 windowScene 赋值 —— iOS 13+ 没挂 scene 的窗口根本不会显示，且不报错"
fi
if grep -q 'WXPBestWindowScene' WXPetWindow.m 2>/dev/null; then
    ok "有场景探测（含「借已有窗口的 scene」兜底）"
else
    bad "缺场景探测函数"
fi
if grep -q 'connectedScenes' WXPetWindow.m 2>/dev/null; then
    ok "遍历 connectedScenes 选场景"
else
    bad "未遍历 connectedScenes"
fi

# ── 6. ⭐ 前台判定链路 ───────────────────────────────────────
echo ""
echo "[6/16] ⭐ 前台判定：多候选 + 被可见性逻辑使用 + fail-closed"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys
f = io.open("WXPFrontmost.m", encoding="utf-8", errors="replace").read()
fc = re.sub(r'//[^\n]*', '', f)
cands = len(re.findall(r'WXPSendObject\(|WXPSendClassObject\(', fc))
if cands >= 6:
    print("  ✅ 前台判定有多候选链（%d 处取值尝试）" % cands)
else:
    print("  ❌ 前台判定候选太少（%d 处）—— 钉死单一私有接口会在真机上静默失效" % cands)
    sys.exit(1)
if "method_copyReturnType" in fc:
    print("  ✅ 转发前校验返回类型（防止把 BOOL 方法当对象方法调）")
else:
    print("  ❌ 缺 method_copyReturnType 校验 —— 私有接口返回类型一变就崩进程")
    sys.exit(1)
if "WXPFrontmostRecon" in f:
    print("  ✅ 有启动侦查（判定失败时能靠日志定位，不用猜）")
else:
    print("  ❌ 缺启动侦查")
    sys.exit(1)

m = io.open("WXPetManager.m", encoding="utf-8", errors="replace").read()
mc = re.sub(r'//[^\n]*', '', m)
if "WXPFrontmostBundleID()" in mc:
    print("  ✅ 管理器确实调用了前台判定")
else:
    print("  ❌ 管理器没调用前台判定 —— 「仅限某些 App」不会生效")
    sys.exit(1)
if re.search(r'WXPAppIDs\(\)\s*containsObject', mc) or "containsObject:fg" in mc:
    print("  ✅ 可见性判定用了 App 白名单")
else:
    print("  ❌ 可见性判定没有用 App 白名单")
    sys.exit(1)
# fail-closed：判定失败时不能默认显示
i = mc.find("- (BOOL)shouldShow")
seg = mc[i:i+700] if i >= 0 else ""
if "return WXPAlwaysShow();" in seg:
    print("  ✅ 判定失败时 fail-closed（默认不显示，需显式打开调试开关才显示）")
else:
    print("  ❌ shouldShow 在判定失败时的行为不明确（必须 fail-closed）")
    sys.exit(1)
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查"
fi

# ── 7. 禁止手写 %init ───────────────────────────────────────
echo ""
echo "[7/16] 禁止手写 %init（Logos 源码实锤：会造成前置引用，编译直接失败）"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys
src = io.open("Tweak.x", encoding="utf-8", errors="replace").read()
t = re.sub(r'//[^\n]*', '', src)
if re.search(r'^\s*%init\b', t, re.M):
    print("  ❌ Tweak.x 出现手写 %init —— 会展开出引用「文件后部才声明」的静态符号，")
    print("     报 use of undeclared identifier / MSHookMessageEx 未声明。删掉它。")
    sys.exit(1)
print("  ✅ 未手写 %init（交给 Logos 默认构造器）")
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查"
fi

# ── 8. 同一个类只能一个 %hook 块 ────────────────────────────
echo ""
echo "[8/16] 同一个类只能有一个 %hook 块"
DUP=$(grep -oE '^%hook[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' Tweak.x 2>/dev/null | awk '{print $2}' | sort | uniq -d)
if [ -n "$DUP" ]; then
    bad "以下类出现了多个 %hook 块（后者会覆盖前者，前面的钩子静默失效）：$(echo "$DUP" | tr '\n' ' ')"
else
    ok "无重复 %hook 类"
fi

# ── 9. 日志格式串里的字面 % 必须转义 ────────────────────────
echo ""
echo "[9/16] 日志格式串的字面 %% 必须写成 %%%%"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys, glob
files = ["Tweak.x", "WXPCommon.m", "WXPFrontmost.m", "WXPetView.m",
         "WXPetWindow.m", "WXPetManager.m"] + glob.glob("Preferences/*.m")
call = re.compile(r'(?:WXPProbeLog|WXPPrefsLog)\s*\(\s*@"((?:[^"\\]|\\.)*)"')
conv = re.compile(r'%[-+ #0-9.*]*[lhqzjt]*[diouxXeEfgGaAcspn@]')
bad = []
for f in files:
    try:
        src = io.open(f, encoding="utf-8", errors="replace").read()
    except IOError:
        continue
    for i, line in enumerate(src.splitlines(), 1):
        m = call.search(line)
        if not m:
            continue
        s = m.group(1)
        probe = s.replace("%%", "\x00")
        hit = False
        for mm in conv.finditer(probe):
            nxt = probe[mm.end():mm.end()+2]
            if len(nxt) == 2 and all(c.isascii() and c.isalpha() for c in nxt):
                hit = True
                break
        if not hit:
            rest = conv.sub("", probe)
            if "%" in rest:
                hit = True
        if hit:
            bad.append((f, i, s))
if bad:
    print("  ❌ 以下日志格式串里 % 没转义（编译报 -Wformat-insufficient-args）：")
    for f, i, s in bad:
        print("     %s:%d  %s" % (f, i, s))
    print("     修法：把 %%orig / %%hook 这类字面量写成 %%%%orig / %%%%hook")
    sys.exit(1)
print("  ✅ 日志格式串检查通过")
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查"
fi

# ── 10. objc 运行时函数必须有可见声明 ───────────────────────
echo ""
echo "[10/16] objc 运行时函数的可见声明"
RUNTIME_API='object_getClass|class_getInstanceMethod|class_getMethodImplementation|method_copyReturnType|method_copyArgumentType|method_getTypeEncoding|objc_getClassList|objc_copyClassList|objc_getClass|class_addMethod|method_setImplementation'
for f in Tweak.x WXPCommon.m WXPFrontmost.m WXPetView.m WXPetWindow.m WXPetManager.m Preferences/WXPetPrefsListController.m; do
    [ -f "$f" ] || continue
    if grep -qE "$RUNTIME_API" "$f"; then
        if grep -qE 'objc/runtime\.h|"WXPCommon\.h"' "$f"; then
            ok "$f 有可见声明"
        else
            bad "$f 用了 objc 运行时函数却没有可见声明（加 #import <objc/runtime.h> 或 #import \"WXPCommon.h\"）"
        fi
    fi
done

# ── 11. ARC 桥接 ────────────────────────────────────────────
echo ""
echo "[11/16] ARC 桥接（ObjC 指针当 C 指针用必须 __bridge）"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys, glob
bad = 0
for path in sorted(glob.glob("*.m") + glob.glob("*.x") + glob.glob("Preferences/*.m")):
    for i, line in enumerate(io.open(path, encoding="utf-8", errors="replace"), 1):
        if "__bridge" in line:
            continue
        s = line.strip()
        if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        for m in re.finditer(r'\(\s*void\s*\*\s*\)\s*([A-Za-z_]\w*)', line):
            t = m.group(1)
            if t.startswith("&"):
                continue
            if re.match(r'^(old|orig|imp|ptr)$', t, re.I):
                continue
            print("  ❌ %s 第 %d 行：`(void *)%s` 需要 __bridge" % (path, i, t))
            bad = 1
if bad:
    sys.exit(1)
print("  ✅ ARC 桥接正确")
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查"
fi

# ── 12. 文件作用域 static 变量必须被使用 ────────────────────
echo ""
echo "[12/16] 文件作用域 static 变量禁止「声明了却没用」"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys, glob
bad = 0
for path in sorted(glob.glob("*.m") + glob.glob("Preferences/*.m")):
    raw = io.open(path, encoding="utf-8", errors="replace").read()
    t = re.sub(r'/\*.*?\*/', '', raw, flags=re.S)
    t = re.sub(r'//[^\n]*', '', t)
    t = re.sub(r'"(?:\\.|[^"\\])*"', '""', t)
    lines = t.splitlines()
    for i, l in enumerate(lines, 1):
        if not l or l[0].isspace():
            continue
        # 只认「顶格」的 static 变量声明（函数定义/声明有括号，跳过）
        m = re.match(r'static\s+(?:const\s+)?.*?\b(\w+)\s*(?:=[^;]*)?;\s*$', l)
        if not m:
            continue
        if '(' in l or '^' in l and '=' not in l:
            continue
        name = m.group(1)
        pat = re.compile(r'(?<![\w])' + re.escape(name) + r'(?![\w])')
        if not any(j != i and pat.search(o) for j, o in enumerate(lines, 1)):
            print("  ❌ %s 第 %d 行的 static 变量 `%s` 声明后从未使用" % (path, i, name))
            print("     Theos 默认 -Werror → -Wunused-variable 会直接让编译失败")
            bad = 1
if bad:
    sys.exit(1)
print("  ✅ 无「声明了却没用」的 static 变量")
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查"
fi

# ── 13. 版本号单一来源 ──────────────────────────────────────
echo ""
echo "[13/16] 版本号一致性（5 处必须完全一致）"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys
def grab(path, pat):
    try:
        t = io.open(path, encoding="utf-8", errors="replace").read()
    except IOError:
        return None
    # ⚠️ 必须带 re.M：control 文件里 Version: 不在第一行，
    #    不带多行模式时 ^ 只匹配字符串开头 → 永远取不到（本脚本第一版就栽在这）
    m = re.search(pat, t, re.M)
    return m.group(1) if m else None

v = {}
v["WXPCommon.h"]      = grab("WXPCommon.h", r'WXP_VERSION\s+@"([0-9.]+)"')
v["control"]          = grab("control", r'^Version:\s*([0-9.]+)')
v["prefs 常量"]        = grab("Preferences/WXPetPrefsListController.m", r'kWXPPrefsVersion\s*=\s*@"([0-9.]+)"')
v["Info.plist"]       = grab("Preferences/Resources/Info.plist", r'CFBundleShortVersionString</key>\s*<string>([0-9.]+)')
v["Root.plist 页脚"]   = grab("Preferences/Resources/Root.plist", r'悬浮宠物 v([0-9.]+)')

print("     " + "  ".join("%s=%s" % (k, val) for k, val in v.items()))
vals = set(val for val in v.values() if val)
missing = [k for k, val in v.items() if not val]
if missing:
    print("  ❌ 取不到版本号：%s" % ", ".join(missing))
    sys.exit(1)
if len(vals) != 1:
    print("  ❌ 版本号不一致 → 诊断页会误报「插件没生效」，把排查带偏")
    sys.exit(1)
print("  ✅ 5 处版本号一致 = %s" % list(vals)[0])
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查"
fi

# ── 14. Root.plist 的 action 必须真有实现 ───────────────────
echo ""
echo "[14/16] Root.plist 的 action 必须在控制器里有实现"
if [ -n "$PY" ]; then
"$PY" - <<'PYEOF'
import io, re, sys
p = io.open("Preferences/Resources/Root.plist", encoding="utf-8", errors="replace").read()
m = io.open("Preferences/WXPetPrefsListController.m", encoding="utf-8", errors="replace").read()
actions = set(re.findall(r'<key>action</key>\s*<string>([^<]+)</string>', p))
code = re.sub(r'//[^\n]*', '', m)
methods = set(re.findall(r'^\s*-\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)', code, re.M))
bad = [a for a in sorted(actions) if a.split(':')[0] not in methods]
if bad:
    print("  ❌ 这些 action 在 WXPetPrefsListController.m 里没有实现：")
    for a in bad:
        print("     - %s" % a)
    print("     Preferences 框架对「plist 写了 action 但方法不存在」不会报任何错，只是点了没反应。")
    sys.exit(1)
print("  ✅ %d 个 action 全部有实现" % len(actions))
sys.exit(0)
PYEOF
if [ $? -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
    bad "缺少 python，跳过该项检查"
fi

# ── 15. PreferenceLoader 入口 plist ─────────────────────────
echo ""
echo "[15/16] PreferenceLoader 入口 plist（必须是 entry 包裹）"
ENTRY="layout/Library/PreferenceLoader/Preferences/WXPet.plist"
if [ -f "$ENTRY" ]; then
    if grep -q '<key>entry</key>' "$ENTRY"; then
        ok "含 entry 包裹"
    else
        bad "缺 entry 包裹 → PreferenceLoader 静默跳过 → 设置里永远没入口"
    fi
    for k in bundle cell detail isController label; do
        if grep -q "<key>$k</key>" "$ENTRY"; then
            ok "entry 内含 $k"
        else
            bad "entry 内缺 $k"
        fi
    done
else
    bad "$ENTRY 不存在"
fi

# ── 16. bundle Info.plist 的 NSPrincipalClass ───────────────
echo ""
echo "[16/16] bundle Info.plist 的 NSPrincipalClass"
INFO="Preferences/Resources/Info.plist"
if [ -f "$INFO" ]; then
    if grep -q '<string>WXPetPrefsListController</string>' "$INFO"; then
        ok "NSPrincipalClass = WXPetPrefsListController"
    elif grep -q '<string>PSListController</string>' "$INFO"; then
        bad "NSPrincipalClass 是抽象基类 PSListController → 点进去白屏，必须写控制器真实类名"
    else
        bad "NSPrincipalClass 未设置或值不对"
    fi
else
    bad "$INFO 不存在（放在 Preferences/ 根目录不会被打进 bundle）"
fi

# ── 汇总 ────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "  通过 $PASS 项，失败 $FAIL 项"
echo "═══════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
    echo "❌ 有 $FAIL 项未通过，先修再推。"
    exit 1
fi
echo "✅ 全部通过，可以推送。"
