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

# 刚装好/重装后，核心登记的插件状态要先回到 running+healthy 再发数据请求：装完接口返回
# 不代表网关到应用的转发路径已经按新容器就绪。轮询核心自己的插件接口（真实就绪信号，最多 60 秒），
# 不是对失败请求重试。
wait_plugin_ready() {
  local waited=0
  while (( waited < 60 )); do
    if smoke_api GET /_wonton/api/plugins 2>/dev/null | python3 -c '
import json, sys
plugins = json.load(sys.stdin)["plugins"]
p = next((p for p in plugins if p["id"] == "app.spliit.spliit"), {})
s = p.get("status") or {}
raise SystemExit(0 if s.get("state") == "running" and s.get("health") == "healthy" else 1)' 2>/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "等了 60 秒核心还没把插件标成 running healthy"
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
