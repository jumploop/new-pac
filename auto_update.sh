#!/bin/bash
set -e

PROJECT_DIR="/root/fanqiang"
TARGET_FILE="cloudflare优选ip"
LOG_FILE="/root/fanqiang/auto_update.log"

# 防止并发（10分钟一次很需要）
exec 9>/tmp/cf_update.lock
flock -n 9 || exit 0

export DISPLAY=:99

cd "$PROJECT_DIR"

echo "===== $(date -u '+%Y-%m-%d %H:%M:%S UTC') =====" >> "$LOG_FILE"

# 启动 Xvfb（若未启动）
pgrep Xvfb >/dev/null 2>&1 || nohup Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 &

# 先同步远端，避免 push rejected
git fetch origin >> "$LOG_FILE" 2>&1
git reset --hard origin/main >> "$LOG_FILE" 2>&1

# 运行抓取脚本
node scripts/update_cf_from_2sites.mjs >> "$LOG_FILE" 2>&1 || true
\
# 没变化就不提交
if git diff --quiet "$TARGET_FILE"; then
  echo "No changes, skip commit." >> "$LOG_FILE"
  exit 0
fi

git add "$TARGET_FILE"

git commit -m "Automated IP update ($(date -u '+%Y-%m-%d %H:%M UTC'))" >> "$LOG_FILE" 2>&1 || {
  echo "Commit failed (maybe nothing to commit)." >> "$LOG_FILE"
  exit 0
}

# push 失败必须算失败（别再假 success）
git push origin main >> "$LOG_FILE" 2>&1 || {
  echo "Push FAILED." >> "$LOG_FILE"
  exit 1
}

echo "Push success." >> "$LOG_FILE"
