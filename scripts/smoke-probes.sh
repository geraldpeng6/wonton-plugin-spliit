# shellcheck shell=bash
# scripts/smoke.sh 的插件探针。
#
# Spliit 没有账号体系：打开网页即用，群组靠链接分享，身份完全由云吞网关保证，
# 所以 identity_check 写 IDENTITY_NA=1（原因见 SMOKE_NOTE）。
# 数据探针走应用自己的 tRPC 接口（/api/trpc，superjson）：建带随机标记的群和账单，重装后读回。
#
# 变量：SMOKE_WEB_URL 应用网页入口；拼 API 路径用 SMOKE_WEB_ORIGIN。
# tRPC 请求要过网关，带核心会话 cookie（-b "$SMOKE_JAR"）；curl 默认不带 Origin/Sec-Fetch-*，
# 网关对无 Origin 的请求按同源处理（插件规范“网关代登录”一节）。
# dev.sh probes 只给 smoke_api/会话助手，不注入 SMOKE_WEB_URL；真正的 smoke 套件才注入。
# 优先用套件给的 SMOKE_WEB_URL/SMOKE_WEB_ORIGIN，没有就从核心的插件列表拿网页地址推导 origin。
web_origin() {
  if [[ -n "${SMOKE_WEB_URL:-}" ]]; then
    echo "${SMOKE_WEB_ORIGIN:-${SMOKE_WEB_URL%/}}"
    return
  fi
  local url scheme host
  if [[ -z "${_WEB_ORIGIN:-}" ]]; then
    url="$(smoke_api GET /_wonton/api/plugins | jq -r '.plugins[] | select(.id=="app.spliit.spliit") | .web_url // ""')"
    url="${url%/}"
    scheme="${url%%://*}"
    host="${url#"$scheme"://}"
    _WEB_ORIGIN="$scheme://${host%%[/?#]*}"
  fi
  echo "$_WEB_ORIGIN"
}

# 首页 hero 文案（messages/en-US.json 的 Homepage.metaTitle），网关错误页不会有它。
web_assert() { grep -q 'Share Expenses with Friends'; }

# 套件按 source 一起读这几个值，export 让 shellcheck 认它们被用。
export IDENTITY_NA=1
export SMOKE_NOTE="Spliit 没有用户/账号体系（tRPC 全部匿名 baseProcedure，群组靠链接分享）；身份由网关保证，匿名访问被 401 挡住"

# tRPC 的返回是 [{result:{data:{json:…}}}]；批量请求体是 {"0":{"json":<superjson input>}}。
_trpc_get() { # <procedure> <input JSON>：带会话 GET，输出响应体
  curl -fsS -b "$SMOKE_JAR" -G "$(web_origin)/api/trpc/$1" \
    --data-urlencode "batch=1" --data-urlencode "input={\"0\":{\"json\":$2}}"
}

_trpc_post() { # <procedure> <input JSON>：带会话 POST，输出响应体
  curl -fsS -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"0\":{\"json\":$2}}" "$(web_origin)/api/trpc/$1?batch=1"
}

# 刚装好/重装后网关到应用的转发路径要过十几秒才稳（核心自己也有十几秒收尾，官方冒烟实测 memos
# 就在这窗口 502）：发数据请求前等两个真实就绪信号，都满足才继续，不对失败请求重试——
# 1) 网关把应用首页真的服务出来（页面特征命中；就是官方冒烟"等首页稳定 200"的做法）；
# 2) 核心把插件标成 running healthy（核心自己的插件接口）。
# 会话不能用现成的：核心重建后旧会话失效，且核心登录发的 cookie 只对核心域名有效，插件域名的
# 会话要经 dweb 的完整登录链重拿。每轮删掉 jar 让 dweb 重新走（dweb 两套套件都有，自带登录跳转）。
# 最多等 90 秒（按墙钟），超时如实报错停下。
wait_plugin_ready() {
  [[ -n "${SMOKE_JAR:-}" ]] || { echo "缺冒烟变量：SMOKE_JAR" >&2; return 1; }
  local deadline=$((SECONDS + 90)) page
  while (( SECONDS < deadline )); do
    rm -f "$SMOKE_JAR"
    page="$(dweb / 2>/dev/null || true)"
    if [[ -n "$page" ]] && web_assert <<<"$page" 2>/dev/null; then
      if smoke_api GET /_wonton/api/plugins 2>/dev/null | python3 -c '
import json, sys
plugins = json.load(sys.stdin)["plugins"]
p = next((p for p in plugins if p["id"] == "app.spliit.spliit"), {})
s = p.get("status") or {}
raise SystemExit(0 if s.get("state") == "running" and s.get("health") == "healthy" else 1)' 2>/dev/null; then
        return 0
      fi
    fi
    sleep 2
  done
  echo "等了 90 秒应用页面经网关还打不开或核心没把插件标成 running healthy"
  return 1
}

data_write() {
  wait_plugin_ready || return 1
  local marker="wonton-$RANDOM$RANDOM$RANDOM" resp gid pid1 pid2 eid
  resp="$(_trpc_post groups.create "{\"groupFormValues\":{\"name\":\"Smoke $marker\",\"currency\":\"USD\",\"currencyCode\":\"USD\",\"participants\":[{\"name\":\"Alice\"},{\"name\":\"Bob\"}]}}")" \
    || { echo "建群失败：$resp"; return 1; }
  gid="$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["result"]["data"]["json"]["groupId"])' <<<"$resp")" \
    || { echo "解析群 id 失败：$resp"; return 1; }

  resp="$(_trpc_get groups.get "{\"groupId\":\"$gid\"}")" \
    || { echo "查群失败：$resp"; return 1; }
  read -r pid1 pid2 <<<"$(python3 -c '
import json,sys
ps = json.load(sys.stdin)[0]["result"]["data"]["json"]["group"]["participants"]
print(ps[0]["id"], ps[1]["id"])' <<<"$resp")" \
    || { echo "解析成员 id 失败：$resp"; return 1; }

  resp="$(_trpc_post groups.expenses.create "{\"groupId\":\"$gid\",\"expenseFormValues\":{\"expenseDate\":\"2026-01-01\",\"title\":\"Smoke $marker\",\"amount\":23.45,\"paidBy\":\"$pid1\",\"paidFor\":[{\"participant\":\"$pid2\",\"shares\":1}],\"splitMode\":\"EVENLY\",\"saveDefaultSplittingOptions\":false,\"isReimbursement\":false,\"documents\":[]}}")" \
    || { echo "记账失败：$resp"; return 1; }
  eid="$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["result"]["data"]["json"]["expenseId"])' <<<"$resp")" \
    || { echo "解析账单 id 失败：$resp"; return 1; }

  printf '%s\n' "$gid $eid $marker" >"$SMOKE_STATE"
}

data_check() {
  wait_plugin_ready || return 1
  local gid eid marker resp
  read -r gid eid marker <"$SMOKE_STATE"
  resp="$(_trpc_get groups.expenses.list "{\"groupId\":\"$gid\",\"limit\":100}")" \
    || { echo "查账单失败：$resp"; return 1; }
  if grep -qF "$marker" <<<"$resp"; then
    return 0
  fi
  echo "重装后找不到标记 $marker（群 $gid 账单 $eid），看到的：$(head -c 300 <<<"$resp")"
  return 1
}
