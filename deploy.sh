#!/bin/bash
# 一键部署 memory-card-app 到 GitHub Pages（带诊断输出）
# 用法：bash deploy.sh <GitHub用户名> <GitHub Token>

if [ $# -lt 2 ]; then
  echo "用法: bash deploy.sh <GitHub用户名> <GitHub Token>"
  exit 1
fi

USER="$1"
TOKEN="$2"
REPO="memory-card-app"
API="https://api.github.com"

[ -f memory-card-app.html ] || { echo "错误: 找不到 memory-card-app.html"; exit 1; }
cp memory-card-app.html index.html

BASE64_STR=$(base64 -w0 -i index.html 2>/dev/null || base64 -b 0 -i index.html)
if [ -z "$BASE64_STR" ]; then echo "错误: base64 编码失败"; exit 1; fi

# 通用 API 调用：打印 HTTP 状态码和响应体
call() {
  # $1=method, $2=url, $3=body(可选)
  local method="$1" url="$2" body="$3" resp http
  if [ -n "$body" ]; then
    resp=$(curl -s -w "\n%{http_code}" -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      "$url" -d "$body")
  else
    resp=$(curl -s -w "\n%{http_code}" -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$url")
  fi
  http=$(printf "%s" "$resp" | tail -1 | tr -cd '0-9')
  body=$(printf "%s" "$resp" | sed '$d')
  echo "$http|$body"
}

echo ">> 检查仓库 $USER/$REPO ..."
R=$(call GET "$API/repos/$USER/$REPO")
ST=$(echo "$R" | cut -d'|' -f1 | tr -cd '0-9')
if [ "$ST" = "404" ]; then
  echo ">> 创建仓库..."
  R=$(call POST "$API/user/repos" "{\"name\":\"$REPO\",\"description\":\"文档记忆卡 · 记忆卡片 + AI题库刷题一体化\",\"private\":false,\"auto_init\":false}")
  ST=$(echo "$R" | cut -d'|' -f1)
  if [ "$ST" != "201" ]; then echo "   创建失败 HTTP $ST: $(echo "$R" | cut -d'|' -f2)"; exit 1; fi
elif [ "$ST" != "200" ]; then
  echo "   仓库检查失败 HTTP $ST: $(echo "$R" | cut -d'|' -f2)"; exit 1
fi

echo ">> 上传文件 (创建 blob)..."
R=$(call POST "$API/repos/$USER/$REPO/git/blobs" "{\"content\":\"$BASE64_STR\",\"encoding\":\"base64\"}")
ST=$(echo "$R" | cut -d'|' -f1)
BODY=$(echo "$R" | cut -d'|' -f2)
if [ "$ST" != "201" ]; then echo "   ❌ blob 失败 HTTP $ST: $BODY"; exit 1; fi
BLOB_SHA=$(echo "$BODY" | grep -o '"sha":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "   blob SHA: $BLOB_SHA"

# parent（main 是否已存在）
PARENT=$(echo $(call GET "$API/repos/$USER/$REPO/git/refs/heads/main") | cut -d'|' -f2 | grep -o '"sha":"[^"]*"' | head -1 | cut -d'"' -f4)

echo ">> 创建 tree + commit..."
R=$(call POST "$API/repos/$USER/$REPO/git/trees" "{\"tree\":[{\"path\":\"index.html\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"$BLOB_SHA\"}]}")
ST=$(echo "$R" | cut -d'|' -f1); BODY=$(echo "$R" | cut -d'|' -f2)
if [ "$ST" != "201" ]; then echo "   ❌ tree 失败 HTTP $ST: $BODY"; exit 1; fi
TREE_SHA=$(echo "$BODY" | grep -o '"sha":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -n "$PARENT" ]; then
  CB="{\"message\":\"Update memory-card-app\",\"tree\":\"$TREE_SHA\",\"parents\":[\"$PARENT\"]}"
else
  CB="{\"message\":\"Initial commit: 文档记忆卡 App\",\"tree\":\"$TREE_SHA\"}"
fi
R=$(call POST "$API/repos/$USER/$REPO/git/commits" "$CB")
ST=$(echo "$R" | cut -d'|' -f1); BODY=$(echo "$R" | cut -d'|' -f2)
if [ "$ST" != "201" ]; then echo "   ❌ commit 失败 HTTP $ST: $BODY"; exit 1; fi
COMMIT_SHA=$(echo "$BODY" | grep -o '"sha":"[^"]*"' | head -1 | cut -d'"' -f4)

echo ">> 推送 main 分支..."
if [ -n "$PARENT" ]; then
  R=$(call PATCH "$API/repos/$USER/$REPO/git/refs/heads/main" "{\"sha\":\"$COMMIT_SHA\"}")
else
  R=$(call POST "$API/repos/$USER/$REPO/git/refs" "{\"ref\":\"refs/heads/main\",\"sha\":\"$COMMIT_SHA\"}")
fi
ST=$(echo "$R" | cut -d'|' -f1)
if [ "$ST" != "200" ] && [ "$ST" != "201" ]; then echo "   ❌ 推送失败 HTTP $ST: $(echo "$R" | cut -d'|' -f2)"; exit 1; fi

echo ">> 开启 GitHub Pages..."
RP=$(call GET "$API/repos/$USER/$REPO/pages")
PST=$(echo "$RP" | cut -d'|' -f1)
if [ "$PST" = "404" ]; then
  R=$(call POST "$API/repos/$USER/$REPO/pages" '{"source":{"branch":"main","path":"/"}}')
  ST=$(echo "$R" | cut -d'|' -f1)
  if [ "$ST" != "201" ]; then echo "   ⚠️ Pages 开启失败 HTTP $ST: $(echo "$R" | cut -d'|' -f2)（可稍后在仓库 Settings → Pages 手动开启）"; fi
else
  echo "   Pages 已开启，跳过"
fi

echo ""
echo "=============================================="
echo "  ✅ 部署完成！"
echo "  仓库: https://github.com/$USER/$REPO"
echo "  在线地址: https://$USER.github.io/$REPO/"
echo "  (GitHub Pages 可能需要 1-2 分钟生效)"
echo "=============================================="
