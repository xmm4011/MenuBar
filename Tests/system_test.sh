#!/bin/bash
# MenuBar 系统测试：在真实菜单栏上把核心功能跑一遍，逐项输出结果。
#
# 用法：Tests/system_test.sh [--rebuild]
#   --rebuild   额外测试「重新编译安装后，布局、授权是否保持」（多花半分钟）
#
# 测试期间菜单栏会收起、展开几次，屏幕上会短暂弹出测试 App、KeyDock 和 MenuBar 自己的菜单，结束后恢复为收起状态。
# 测试过程中请不要把鼠标放在菜单栏上，否则自动收起会被推迟，相关项会跳过。
set -u
cd "$(dirname "$0")/.."

LOG="$HOME/Library/Logs/MenuBar.log"
OUT="build.noindex/test"
INSPECT="$OUT/inspect"
PROBE="$OUT/MBProbe.app"
PASS=0; FAIL=0; SKIP=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  ⏭  $1"; SKIP=$((SKIP + 1)); }
check() { if [ "$1" -eq 1 ] 2>/dev/null; then pass "$2"; else fail "$2"; fi; }

# 这台机器正在被人使用时，点击会关掉弹出菜单、移动会打乱模拟拖动。
# 涉及菜单和鼠标的步骤：开始前等用户停下来（2 秒没有输入），并记下鼠标位置；
# 测试自己发出的鼠标事件结束后都会把鼠标放回原处，所以鼠标位置变了，就说明有人动过。
wait_idle() {
  local waited=0
  while [ "$("$INSPECT" idle)" -lt 2 ]; do
    [ "$waited" -eq 0 ] && echo "     （检测到鼠标或键盘操作，等你停下来再继续…）"
    sleep 1; waited=$((waited + 1))
    [ "$waited" -ge 60 ] && return 1
  done
  return 0
}
# 菜单开着时键盘输入也会被菜单接走（回车会选中、Esc 会关掉），所以按键也算
STEP_CURSOR=""; STEP_START=0
step_begin()  { wait_idle; STEP_CURSOR=$("$INSPECT" cursor); STEP_START=$(date +%s); }
interfered()  {
  [ "$("$INSPECT" cursor)" != "$STEP_CURSOR" ] || [ "$("$INSPECT" keyidle)" -lt $(( $(date +%s) - STEP_START )) ]
}
# 和 check 一样，但失败时如果期间有人动过鼠标，记为跳过而不是失败
check_step() {
  if [ "$1" -ne 1 ] 2>/dev/null && interfered; then
    skip "$2（期间有人动了鼠标或键盘，结果不算）"
  else
    check "$1" "$2"
  fi
}
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
echo "测试大约需要 3 分钟，期间请不要碰鼠标和菜单栏。"

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
  do_expand
  url collapse; wait_until 6 is_collapsed; sleep 0.6
  glued_ok && [ "$(left_onscreen "$(toggle_x)")" = "0" ] && OK=$((OK + 1))
done
[ "$OK" -eq 10 ] && c=1 || c=0; check $c "连续收起 10 次，每次都贴住箭头且收得干净（${OK}/10）"
OK=0
for i in 1 2 3; do
  do_expand
  url collapse; url expand; sleep 2.5      # 收起还没完成就要求展开
  is_expanded && OK=$((OK + 1))
done
[ "$OK" -eq 3 ] && c=1 || c=0; check $c "收起过程中要求展开，最终停在展开状态（${OK}/3）"
OK=0
for i in 1 2 3; do
  do_collapse
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
step_begin
url "open?app=MBProbe"; sleep 2.5
read -r PX PY <<< "$(popup_of MBProbe)"
[ -n "${PX:-}" ] && [ "$PX" -ge 0 ] && [ "$PX" -lt "$SCREEN_W" ] && [ "$PY" -lt 60 ] && c=1 || c=0
check_step $c "菜单弹在屏幕上（x=${PX:-无} y=${PY:-无}）"
is_collapsed && c=0 || c=1; check $c "菜单栏自动展开"
stop_probe

# ---------------------------------------------------------------- 5
section "5. 打开被刘海挡住的图标（展开状态）"
do_expand
start_probe
D=$(debug_lines)
PROBE_STATE=$(echo "$D" | grep "MBProbe" | grep -o "HIDDEN\|visible" | head -1)
echo "     测试图标当前：$([ "$PROBE_STATE" = "HIDDEN" ] && echo "被刘海挡住" || echo "可见")"
step_begin
url "open?app=MBProbe"; sleep 2
read -r PX PY <<< "$(popup_of MBProbe)"
[ -n "${PX:-}" ] && [ "$PX" -ge 0 ] && [ "$PX" -lt "$SCREEN_W" ] && [ "$PY" -lt 60 ] && c=1 || c=0
check_step $c "菜单弹在屏幕上（x=${PX:-无} y=${PY:-无}）"
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
  step_begin
  url "open?app=MBProbe"; sleep 2
  [ -n "$(popup_of MBProbe)" ] && c=1 || c=0; check_step $c "测试菜单已打开"
  sleep $(( AUTO + 3 ))
  is_collapsed && c=0 || c=1; check_step $c "有菜单开着时不自动收起（展开后等了 $(( AUTO + 6 )) 秒）"
  stop_probe
  wait_until 6 is_collapsed && c=1 || c=0; check $c "菜单关闭后很快自动收起"
  do_expand
  wait_until $(( AUTO + 5 )) is_collapsed && c=1 || c=0; check $c "没有操作时 ${AUTO} 秒后自动收起"
fi

# ---------------------------------------------------------------- 7
section "7. 打开真实 App 的图标（KeyDock）"
if pgrep -x KeyDock >/dev/null; then
  do_collapse
  step_begin
  url "open?app=KeyDock"; sleep 2.5
  read -r KX KY <<< "$(popup_of KeyDock)"
  [ -n "${KX:-}" ] && [ "$KX" -ge 0 ] && [ "$KX" -lt "$SCREEN_W" ] && c=1 || c=0
  check_step $c "KeyDock 的菜单弹在屏幕上（x=${KX:-无} y=${KY:-无}）"
  url dismiss      # 发 Esc 关掉菜单
  wait_until 4 bash -c "[ -z \"\$('$INSPECT' popups | grep '^KeyDock')\" ]" && c=1 || c=0
  check $c "测试结束后关掉了 KeyDock 的菜单"
else
  skip "KeyDock 没有运行"
fi

# ---------------------------------------------------------------- 7b
section "7b. 重新启动"
for MODE in 展开 收起; do
  if [ "$MODE" = "展开" ]; then do_expand; else do_collapse; fi
  pkill -x MenuBar; sleep 1; open /Applications/MenuBar.app
  wait_until 10 is_collapsed; sleep 0.6
  glued_ok && [ "$(left_onscreen "$(toggle_x)")" = "0" ] && c=1 || c=0
  check $c "在${MODE}状态下退出，重新打开后自动收起且收得干净"
  [ "$(right_set "$(toggle_x)")" = "$R_COLLAPSED" ] && c=1 || c=0; check $c "常驻图标保持不变"
done

# ---------------------------------------------------------------- 8
section "8. 重新编译安装后保持布局和授权"
if [ "${1:-}" = "--rebuild" ]; then
  do_expand
  T_BEFORE=$(toggle_x)
  ./build.sh install >/dev/null 2>&1
  wait_until 10 is_collapsed && sleep 0.6 && glued_ok && [ "$(left_onscreen "$(toggle_x)")" = "0" ] && c=1 || c=0
  check $c "启动后自动收起且收得干净"
  [ "$(toggle_x)" = "$T_BEFORE" ] && c=1 || c=0; check $c "箭头位置保持不变（$(toggle_x)）"
  [ "$(right_set "$(toggle_x)")" = "$R_COLLAPSED" ] && c=1 || c=0; check $c "常驻图标保持不变"
  D=$(debug_lines)
  [ "$(kv "$D" trusted)" = "true" ] && c=1 || c=0; check $c "辅助功能权限仍然有效"
else
  skip "加 --rebuild 参数才测试"
fi

# ---------------------------------------------------------------- 9
section "9. 列表：单击打开、按住 ⌘ 拖动调整顺序"
# 三个测试图标 ALPHA / BRAVO / CHARLIE，事先写好位置，让它们排在箭头左边：从左到右 Charlie Bravo Alpha
start_trio() {
  local tp n
  stop_probe
  tp=$(defaults read com.local.MenuBar "NSStatusItem Preferred Position MenuBar.Toggle" 2>/dev/null || echo 0)
  defaults delete local.menubar.probe 2>/dev/null
  for n in Alpha:10 Bravo:25 Charlie:40; do
    defaults write local.menubar.probe "NSStatusItem Preferred Position Probe${n%%:*}" -float "$(echo "$tp + ${n##*:}" | bc)"
  done
  open -n "$PROBE" --args --trio; sleep 2.5
}
stop_trio()   { stop_probe; defaults delete local.menubar.probe 2>/dev/null; }
probe_order() { win | sort -n | awk -F'\t' '$4 ~ /^Probe/ {sub("Probe", "", $4); printf "%s ", $4}' | sed 's/ $//'; }
# 你自己的图标（箭头左边、不含测试图标）按窗口编号排的顺序，用来确认测试没有打乱它们
user_order()  { win | sort -n | awk -F'\t' -v t="$(toggle_x)" '$1<t && $2<400 && $4 !~ /^Probe/ {printf "%s ", $5}'; }
# 两份窗口编号列表里共同出现的那些，先后顺序是否一致（有的 App 更新图标时会换新窗口，忽略这些）
same_relative_order() {
  [ "$(echo "$1" | tr ' ' '\n' | grep -xF -f <(echo "$2" | tr ' ' '\n') | tr '\n' ' ')" = \
    "$(echo "$2" | tr ' ' '\n' | grep -xF -f <(echo "$1" | tr ' ' '\n') | tr '\n' ' ')" ]
}
urlenc()      { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }
trio_hidden() { [ "$(debug_lines | grep -c "HIDDEN.*MBProbe")" = "3" ]; }

# 发一条命令，等日志里出现指定内容（正则），把这段日志输出出来
url_wait() {   # url_wait <命令> <正则> <秒>
  local before i
  before=$(wc -l < "$LOG" | tr -d ' ')
  url "$1"
  for i in $(seq 1 $(( $3 * 4 ))); do
    sleep 0.25
    if tail -n +$((before + 1)) "$LOG" | grep -qE "$2"; then tail -n +$((before + 1)) "$LOG"; return 0; fi
  done
  tail -n +$((before + 1)) "$LOG"
  return 1
}

# 拖一次，检查结果顺序和收起状态是否恢复
reorder_case() {   # reorder_case <参数> <期望顺序> <说明>
  local out
  step_begin
  out=$(url_wait "testreorder?$1" "reorder: (done|failed)|row not found" 15)
  wait_until 6 is_collapsed; sleep 0.6
  echo "$out" | grep -q "reorder: done" && [ "$(probe_order)" = "$2" ] && c=1 || c=0
  check_step $c "$3：$(probe_order)（期望 $2）"
}

do_collapse
start_trio
wait_until 10 trio_hidden && c=1 || c=0
check $c "三个测试图标都在收起列表里（从左到右 $(probe_order)）"

LB=$(wc -l < "$LOG" | tr -d ' ')
step_begin
url_wait "testclick?item=alpha" "press MBProbe — ALPHA" 10 >/dev/null
sleep 1.5      # 如果有重复点击，会在这段时间里出现
read -r PX PY <<< "$(popup_of MBProbe)"
[ -n "${PX:-}" ] && [ "$PX" -ge 0 ] && [ "$PX" -lt "$SCREEN_W" ] && [ "$PY" -lt 60 ] && c=1 || c=0
check_step $c "单击列表里的一行，打开了对应图标的菜单（x=${PX:-无} y=${PY:-无}）"
[ "$(tail -n +$((LB + 1)) "$LOG" | grep -c "press MBProbe")" = "1" ] && c=1 || c=0; check $c "只打开一次，没有重复点击"
url dismiss
wait_until 4 bash -c "[ -z \"\$('$INSPECT' popups | grep '^MBProbe')\" ]"

# 展开后测试图标必须都在屏幕上，否则（被刘海挡住）系统不让拖
do_expand
TRIO_VISIBLE=$(debug_lines | grep -c "visible.*MBProbe")
do_collapse
if [ "$TRIO_VISIBLE" != "3" ]; then
  skip "展开后测试图标被刘海挡住（菜单栏太挤），无法测试拖动排序"
else
  USER_ORDER=$(user_order)
  reorder_case "item=alpha&before=charlie" "Alpha Charlie Bravo" "往左拖到最前面"
  reorder_case "item=alpha&before=bravo"   "Charlie Alpha Bravo" "往右拖，隔一个图标"
  reorder_case "item=charlie"              "Alpha Bravo Charlie" "拖到最后"
  glued_ok && [ "$(left_onscreen "$(toggle_x)")" = "0" ] && c=1 || c=0
  check $c "每次调完都恢复收起，且收得干净"

  step_begin
  out=$(url_wait "testreorder?item=bravo&before=alpha&reopen=2" "reorder: reopen menu|reorder: failed" 15)
  wait_until 4 bash -c "'$INSPECT' popups | grep -q '^MenuBar'" && c=1 || c=0
  check_step $c "调完重新打开列表，显示新顺序（$(probe_order)）"
  wait_until 6 bash -c "! '$INSPECT' popups | grep -q '^MenuBar'"

  # 拖到最靠近刘海的位置：展开后最左边那个看得见的图标前面。
  # 展开时系统会把一部分图标藏到刘海后面（不一定是最左边的），这里最容易出错
  do_expand
  EDGE=$(debug_lines | grep "visible" | head -1 | sed -E 's/.* w=[0-9]+ //; s/ — .*//')
  do_collapse
  if [ -z "$EDGE" ] || [ "$EDGE" = "MBProbe" ]; then
    skip "展开后最左边看得见的是测试图标，无法测试拖到刘海边上"
  else
    step_begin
    out=$(url_wait "testreorder?item=alpha&before=$(urlenc "$EDGE")" "reorder: (done|failed)|row not found" 20)
    wait_until 6 is_collapsed; sleep 0.6
    if echo "$out" | grep -q "reorder: failed.*已经挪过去了"; then
      # 离刘海太近时，macOS 可能在挪动后把它藏到刘海后面，这是系统行为，程序能正确识别并说明即可
      skip "拖到刘海边上（「${EDGE}」前面）：挪动后被 macOS 藏到刘海后面，已正确提示（系统限制）"
      EDGE_HIDDEN=1
    else
      echo "$out" | grep -q "reorder: done" && [ "$(probe_order)" = "Alpha Bravo Charlie" ] && c=1 || c=0
      check_step $c "拖到刘海边上（「${EDGE}」前面）：拖了 $(echo "$out" | grep -c "reorder: drag") 次，核对通过"
    fi
  fi
  if [ "${EDGE_HIDDEN:-0}" = "1" ]; then
    skip "再拖回最后：测试图标被藏在刘海后面，拖不了"
  else
    reorder_case "item=alpha" "Bravo Charlie Alpha" "再拖回最后"
  fi
  same_relative_order "$(user_order)" "$USER_ORDER" && c=1 || c=0
  check $c "你自己的图标相对顺序没被打乱"
fi

# 展开后仍被刘海挡住的图标：应该提示无法拖动，并且什么都不改
do_expand
NOTCH=$(debug_lines | grep "HIDDEN" | head -1 | sed -E 's/.* w=[0-9]+ //; s/ — .*//')
do_collapse
if [ -z "$NOTCH" ]; then
  skip "展开后没有被刘海挡住的图标，无法测试"
else
  BEFORE=$(win | sort -n | awk -F'\t' '{print $5}' | tr '\n' ' ')
  step_begin
  out=$(url_wait "testreorder?item=$(urlenc "$NOTCH")" "reorder: (done|failed)|row not found" 15)
  wait_until 6 is_collapsed; sleep 0.6
  echo "$out" | grep -q "reorder: failed.*刘海" && c=1 || c=0
  check_step $c "拖动被刘海挡住的「${NOTCH}」时提示系统不允许"
  same_relative_order "$(win | sort -n | awk -F'\t' '{print $5}' | tr '\n' ' ')" "$BEFORE" && glued_ok && c=1 || c=0
  check $c "菜单栏顺序没变，并恢复收起"
fi
stop_trio

section "未覆盖"
skip "全局快捷键 ⌃⌥⌘B：需要真实按键，脚本无法模拟"
skip "按住 ⌘ 拖动箭头本身：系统自带功能，测试会打乱你的布局，不测"

# ---------------------------------------------------------------- 收尾
url collapse
echo
# 测试图标是临时的，别让系统一直记着它（聚焦搜索里也就不会出现）
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PROBE" 2>/dev/null || true
echo "结果：通过 $PASS 项，失败 $FAIL 项，跳过 $SKIP 项"
[ "$FAIL" -eq 0 ]
