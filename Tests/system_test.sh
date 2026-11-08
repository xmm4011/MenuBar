#!/bin/bash
# MenuBar 系统测试：在真实菜单栏上把核心功能跑一遍，逐项输出结果。
#
# 用法：Tests/system_test.sh [--rebuild]
#   --rebuild   额外测试「重新编译安装后，布局、授权是否保持」（多花半分钟）
#
# 测试期间菜单栏会收起、展开几次，屏幕上会短暂弹出测试 App 和 KeyDock 的菜单，结束后恢复为收起状态。
# 测试过程中请不要把鼠标放在菜单栏上，否则自动收起会被推迟，相关项会跳过。
set -u
cd "$(dirname "$0")/.."

LOG="$HOME/Library/Logs/MenuBar.log"
OUT="build/test"
INSPECT="$OUT/inspect"
PROBE="$OUT/MBProbe.app"
PASS=0; FAIL=0; SKIP=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  ⏭  $1"; SKIP=$((SKIP + 1)); }
check() { if [ "$1" -eq 1 ] 2>/dev/null; then pass "$2"; else fail "$2"; fi; }
section() { echo; echo "【$1】"; }

url()           { open -g "menubar://$1"; }
win()           { "$INSPECT" windows; }
toggle_x()      { win | awk -F'\t' '$4=="MenuBar.Toggle" {print $1; exit}'; }
sep_info()      { win | awk -F'\t' '$4=="MenuBar.Separator" {print $1, $2, $3; exit}'; }
right_set()     { win | awk -F'\t' -v t="$1" '$1>t && $3=="on" {print $1":"$2}' | sort -n | tr '\n' ' '; }
left_onscreen() { win | awk -F'\t' -v t="$1" '$1<t && $3=="on"' | wc -l | tr -d ' '; }
left_total()    { win | awk -F'\t' -v t="$1" '$1<t && $4!="MenuBar.Separator"' | wc -l | tr -d ' '; }
popup_of()      { "$INSPECT" popups | awk -F'\t' -v o="$1" '$1==o {print $2, $3; exit}'; }
is_collapsed()  { local s; s=$(sep_info); [ -n "$s" ] && [ "$(echo "$s" | awk '{print $2}')" -gt 200 ]; }
is_expanded()   { [ -z "$(sep_info)" ]; }
mouse_in_bar()  { [ "$("$INSPECT" mouse)" = "menubar" ]; }

# 让 MenuBar 把当前状态写进日志，返回这次的日志。
# 每次带一个唯一编号，只认对应编号的回复，避免和别的输出混在一起
debug_lines() {
  local before token i
  token="t$$_$RANDOM$RANDOM"
  before=$(wc -l < "$LOG" | tr -d ' ')
  url "debug?token=$token${1:+&$1}"
  for i in $(seq 1 60); do
    sleep 0.25
    if tail -n +$((before + 1)) "$LOG" | grep -q "done token=$token"; then
      tail -n +$((before + 1)) "$LOG" | sed "/done token=$token/q"
      return 0
    fi
  done
  echo "TIMEOUT"
  return 1
}

# 收起 / 展开，并确认真的完成了
do_collapse() { url collapse; wait_until 6 is_collapsed || { fail "收起没有在 6 秒内完成"; return 1; }; sleep 0.6; }
glued_ok()    { local t sx sw; t=$(toggle_x); read -r sx sw _ <<< "$(sep_info)"; [ -n "${sx:-}" ] && [ $(( sx + sw - t )) -ge -3 ] && [ $(( sx + sw - t )) -le 3 ]; }
do_expand()   { url expand;   wait_until 6 is_expanded  || { fail "展开没有在 6 秒内完成"; return 1; }; sleep 1; }
kv()      { echo "$1" | grep -o "$2=[^ ]*" | head -1 | cut -d= -f2; }
scan_ms() { echo "$1" | sed -nE 's/.* in ([0-9]+)ms.*/\1/p' | head -1; }

wait_until() {   # wait_until <秒> <命令...>
  local deadline=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -le "$deadline" ]; do "$@" && return 0; sleep 0.5; done
  return 1
}

start_probe() { pkill -x MBProbe 2>/dev/null; sleep 0.5; open -n "$PROBE"; sleep 2.5; }
stop_probe()  { pkill -x MBProbe 2>/dev/null; sleep 1; }

# ---------------------------------------------------------------- 准备
mkdir -p "$OUT" "$PROBE/Contents/MacOS"
swiftc -O Tests/inspect.swift -o "$INSPECT" 2>/dev/null || { echo "编译 inspect 失败"; exit 1; }
swiftc -swift-version 5 Tests/Probe.swift -o "$PROBE/Contents/MacOS/MBProbe" 2>/dev/null || { echo "编译 Probe 失败"; exit 1; }
cat > "$PROBE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MBProbe</string>
<key>CFBundleIdentifier</key><string>local.menubar.probe</string>
<key>CFBundleName</key><string>MBProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$PROBE" 2>/dev/null
stop_probe
pgrep -x MenuBar >/dev/null || { open /Applications/MenuBar.app; sleep 4; }
SCREEN_W=$("$INSPECT" screen)
if "$INSPECT" popups | grep -q "^MenuBar"; then
  echo "MenuBar 的菜单正开着（菜单开着时它不处理命令），请先点别处关掉…"
  wait_until 30 bash -c "! '$INSPECT' popups | grep -q '^MenuBar'" || { echo "菜单一直开着，测试中止"; exit 1; }
fi
echo "测试大约需要 2 分钟，期间请不要点菜单栏。"

echo "MenuBar 系统测试  $(date '+%Y-%m-%d %H:%M:%S')  屏幕宽度 ${SCREEN_W}"

# ---------------------------------------------------------------- 1
section "1. 基础状态"
pgrep -x MenuBar >/dev/null && c=1 || c=0; check $c "MenuBar 正在运行"
codesign -d -r- /Applications/MenuBar.app 2>&1 | grep -q "certificate leaf" && c=1 || c=0
check $c "使用固定的本地证书签名（重新编译不丢授权）"
D=$(debug_lines) && c=1 || c=0; check $c "MenuBar 能及时响应命令"
[ "$(kv "$D" trusted)" = "true" ] && c=1 || c=0; check $c "已获得辅助功能权限"
AUTO=$(kv "$D" autoCollapse); AUTO=${AUTO%s}

# ---------------------------------------------------------------- 2
section "2. 收起"
do_collapse
T=$(toggle_x); read -r SX SW SON <<< "$(sep_info)"
[ -n "${SX:-}" ] && [ "$SW" -gt 200 ] && c=1 || c=0; check $c "隐形分隔图标已放出并拉宽（宽 ${SW:-无}）"
[ -n "${SX:-}" ] && [ $(( SX + SW - T )) -ge -3 ] && [ $(( SX + SW - T )) -le 3 ] && c=1 || c=0
check $c "分隔图标紧贴箭头左边（右边缘 $(( ${SX:-0} + ${SW:-0} ))，箭头 ${T}）"
[ "$(left_onscreen "$T")" = "0" ] && c=1 || c=0; check $c "箭头左边没有任何图标留在屏幕上"
R_COLLAPSED=$(right_set "$T")
N_RIGHT=$(echo "$R_COLLAPSED" | wc -w | tr -d ' ')
echo "     箭头右边显示 ${N_RIGHT} 个（含控制中心和时钟）：$R_COLLAPSED"
HIDDEN_COLLAPSED=$(left_total "$T")
D=$(debug_lines)
[ "$(kv "$D" hidden)" = "$(kv "$D" hiddenWindows)" ] && c=1 || c=0
check $c "看不到的图标全部识别：读到 $(kv "$D" hidden) 个，系统统计 $(kv "$D" hiddenWindows) 个"
echo "$D" | grep -q "无法识别" && c=0 || c=1; check $c "列表里没有「无法识别」"
if pgrep -x KeyDock >/dev/null; then
  echo "$D" | grep -q "HIDDEN.*KeyDock\|visible.*KeyDock" && c=1 || c=0; check $c "能读到 KeyDock 的图标"
fi

# ---------------------------------------------------------------- 3
section "3. 展开"
do_expand
[ -z "$(sep_info)" ] && c=1 || c=0; check $c "分隔图标已从菜单栏移除，不占位置"
[ "$(toggle_x)" = "$T" ] && c=1 || c=0; check $c "箭头位置不变（$(toggle_x)）"
[ "$(right_set "$T")" = "$R_COLLAPSED" ] && c=1 || c=0; check $c "常驻图标数量和位置都不变"
[ "$(left_total "$T")" = "$HIDDEN_COLLAPSED" ] && c=1 || c=0
check $c "收起的 $HIDDEN_COLLAPSED 个图标全部回到箭头左边（其中 $(left_onscreen "$T") 个在屏幕上，其余被刘海挡住）"
D=$(debug_lines); D2=$(debug_lines)      # 第二次是缓存生效后的正常速度
[ "$(kv "$D2" hidden)" = "$(kv "$D2" hiddenWindows)" ] && c=1 || c=0
check $c "被刘海挡住的图标全部识别：读到 $(kv "$D2" hidden) 个，系统统计 $(kv "$D2" hiddenWindows) 个"
MS=$(scan_ms "$D2"); [ -n "$MS" ] && [ "$MS" -lt 200 ] && c=1 || c=0; check $c "扫描耗时 ${MS}ms（要求 < 200ms）"

# ---------------------------------------------------------------- 3b
section "3b. 稳定性"
OK=0
for i in $(seq 1 10); do
  do_expand >/dev/null
  url collapse; wait_until 6 is_collapsed; sleep 0.6
  glued_ok && [ "$(left_onscreen "$(toggle_x)")" = "0" ] && OK=$((OK + 1))
done
[ "$OK" -eq 10 ] && c=1 || c=0; check $c "连续收起 10 次，每次都贴住箭头且收得干净（${OK}/10）"
OK=0
for i in 1 2 3; do
  do_expand >/dev/null
  url collapse; url expand; sleep 2.5      # 收起还没完成就要求展开
  is_expanded && OK=$((OK + 1))
done
[ "$OK" -eq 3 ] && c=1 || c=0; check $c "收起过程中要求展开，最终停在展开状态（${OK}/3）"
OK=0
for i in 1 2 3; do
  do_collapse >/dev/null
  url toggle; sleep 1.5; is_expanded || continue
  url toggle; sleep 1.5; is_collapsed && glued_ok && OK=$((OK + 1))
done
[ "$OK" -eq 3 ] && c=1 || c=0; check $c "切换命令来回切换正常（${OK}/3）"

# ---------------------------------------------------------------- 4
section "4. 从列表打开被收起的图标"
do_collapse
start_probe
D=$(debug_lines)
echo "$D" | grep -q "HIDDEN.*MBProbe" && c=1 || c=0; check $c "测试图标在收起状态下被列为看不到"
url "open?app=MBProbe"; sleep 2.5
read -r PX PY <<< "$(popup_of MBProbe)"
[ -n "${PX:-}" ] && [ "$PX" -ge 0 ] && [ "$PX" -lt "$SCREEN_W" ] && [ "$PY" -lt 60 ] && c=1 || c=0
check $c "菜单弹在屏幕上（x=${PX:-无} y=${PY:-无}）"
is_collapsed && c=0 || c=1; check $c "菜单栏自动展开"
stop_probe

# ---------------------------------------------------------------- 5
section "5. 打开被刘海挡住的图标（展开状态）"
do_expand
start_probe
D=$(debug_lines)
PROBE_STATE=$(echo "$D" | grep "MBProbe" | grep -o "HIDDEN\|visible" | head -1)
echo "     测试图标当前：$([ "$PROBE_STATE" = "HIDDEN" ] && echo "被刘海挡住" || echo "可见")"
url "open?app=MBProbe"; sleep 2
read -r PX PY <<< "$(popup_of MBProbe)"
[ -n "${PX:-}" ] && [ "$PX" -ge 0 ] && [ "$PX" -lt "$SCREEN_W" ] && [ "$PY" -lt 60 ] && c=1 || c=0
check $c "菜单弹在屏幕上（x=${PX:-无} y=${PY:-无}）"
stop_probe

# ---------------------------------------------------------------- 6
section "6. 自动收起"
stop_probe
if [ "${AUTO:-0}" = "0" ]; then
  skip "自动收起已关闭"
elif mouse_in_bar; then
  skip "鼠标在菜单栏上，自动收起会被推迟，无法测试"
else
  # 先收起再展开，让自动收起重新计时，不受前面步骤影响
  do_collapse; do_expand
  start_probe
  url "open?app=MBProbe"; sleep 2
  [ -n "$(popup_of MBProbe)" ] && c=1 || c=0; check $c "测试菜单已打开"
  sleep $(( AUTO + 3 ))
  is_collapsed && c=0 || c=1; check $c "有菜单开着时不自动收起（展开后等了 $(( AUTO + 6 )) 秒）"
  stop_probe
  wait_until 6 is_collapsed && c=1 || c=0; check $c "菜单关闭后很快自动收起"
  do_expand
  wait_until $(( AUTO + 5 )) is_collapsed && c=1 || c=0; check $c "没有操作时 ${AUTO} 秒后自动收起"
fi

# ---------------------------------------------------------------- 7
section "7. 打开真实 App 的图标（KeyDock）"
if pgrep -x KeyDock >/dev/null; then
  do_collapse
  url "open?app=KeyDock"; sleep 2.5
  read -r KX KY <<< "$(popup_of KeyDock)"
  [ -n "${KX:-}" ] && [ "$KX" -ge 0 ] && [ "$KX" -lt "$SCREEN_W" ] && c=1 || c=0
  check $c "KeyDock 的菜单弹在屏幕上（x=${KX:-无} y=${KY:-无}）"
  url dismiss      # 发 Esc 关掉菜单
  wait_until 4 bash -c "[ -z \"\$('$INSPECT' popups | grep '^KeyDock')\" ]" && c=1 || c=0
  check $c "测试结束后关掉了 KeyDock 的菜单"
else
  skip "KeyDock 没有运行"
fi

# ---------------------------------------------------------------- 8
section "8. 重新编译安装后保持布局和授权"
if [ "${1:-}" = "--rebuild" ]; then
  do_expand
  T_BEFORE=$(toggle_x)
  ./build.sh install >/dev/null 2>&1
  wait_until 10 is_collapsed && c=1 || c=0; check $c "启动后自动收起"
  [ "$(toggle_x)" = "$T_BEFORE" ] && c=1 || c=0; check $c "箭头位置保持不变（$(toggle_x)）"
  [ "$(right_set "$(toggle_x)")" = "$R_COLLAPSED" ] && c=1 || c=0; check $c "常驻图标保持不变"
  D=$(debug_lines)
  [ "$(kv "$D" trusted)" = "true" ] && c=1 || c=0; check $c "辅助功能权限仍然有效"
else
  skip "加 --rebuild 参数才测试"
fi

section "未覆盖"
skip "全局快捷键 ⌃⌥⌘B：需要真实按键，脚本无法模拟"
skip "用鼠标拖动箭头：需要真实拖动，脚本无法模拟"

# ---------------------------------------------------------------- 收尾
url collapse
echo
echo "结果：通过 $PASS 项，失败 $FAIL 项，跳过 $SKIP 项"
[ "$FAIL" -eq 0 ]
