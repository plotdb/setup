#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# VM 一鍵初始化腳本 (based on bootstrap.md)
# 前置條件: 以 root 或有 sudo 權限的帳號執行
# ─────────────────────────────────────────────

WEB_USER="web"           # 建立的 web 用戶名稱

# ─── 顏色輸出 ──────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

# ─── 1. 基本套件 ───────────────────────────────
info "更新 apt 並安裝基本套件..."
sudo apt-get update -y
sudo apt-get install -y \
  screen vim git nginx \
  nodejs build-essential gcc g++ make \
  wget curl rsync snapd \
  fonts-noto-cjk
ok "基本套件安裝完成"

# ─── 3. Node.js (nodesource) ──────────────────
# 若系統 nodejs 版本過舊, 先用 nodesource 裝新版
if ! node --version 2>/dev/null | grep -qE '^v(18|20|22|23|24)' || ! npm --version &>/dev/null; then
  info "安裝 Node.js 20.x (nodesource)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  ok "Node.js $(node --version) 安裝完成"
else
  ok "Node.js $(node --version) 已存在, 跳過"
fi

# ─── 4. tj/n + livescript ─────────────────────
info "安裝 tj/n 與 livescript..."
sudo npm install -g n
N_USE_XZ=0 sudo -E n latest
# 刷新 PATH 以使用剛裝好的 node
export PATH="/usr/local/bin:$PATH"
sudo npm install -g livescript
ok "n 與 livescript 安裝完成 (node: $(node --version))"

# ─── 5. PostgreSQL ────────────────────────────
info "安裝 PostgreSQL..."
sudo apt-get install -y postgresql
ok "PostgreSQL 安裝完成 ($(psql --version))"

# ─── 6. Chrome + Puppeteer 依賴 ───────────────
info "下載並安裝 Google Chrome stable (供 Puppeteer 使用)..."
wget -q -P /tmp https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt install -y /tmp/google-chrome-stable_current_amd64.deb
rm -f /tmp/google-chrome-stable_current_amd64.deb
ok "Chrome 安裝完成"

# ─── 7. 建立 web 用戶 ─────────────────────────
if ! id "$WEB_USER" &>/dev/null; then
  info "建立用戶 $WEB_USER (空白密碼)..."
  sudo adduser --disabled-password --gecos "" "$WEB_USER"
  ok "用戶 $WEB_USER 建立完成"
else
  ok "用戶 $WEB_USER 已存在, 跳過"
fi

# ─── 8. certbot (snapd) ───────────────────────
info "安裝 certbot (via snapd)..."
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
ok "certbot 安裝完成"

# ─── 10. nginx 快取目錄權限 ───────────────────
info "修正 nginx proxy 快取目錄權限..."
if [ -d /var/lib/nginx/proxy ]; then
  sudo chown -R www-data /var/lib/nginx/proxy
fi
ok "nginx 快取目錄設定完成"

# ─── 11. logrotate for nginx ──────────────────
info "設定 nginx logrotate..."
sudo tee /etc/logrotate.d/nginx > /dev/null <<'EOF'
/var/log/nginx/*.log {
  daily
  missingok
  rotate 365
  compress
  delaycompress
  notifempty
  create 640 nginx adm
  sharedscripts
  postrotate
    if [ -f /var/run/nginx.pid ]; then
      kill -USR1 `cat /var/run/nginx.pid`
    fi
  endscript
}
EOF
ok "logrotate 設定完成"

# ─── dotfiles: 偵測執行者 ────────────────────────
# 若透過 sudo 執行, SUDO_USER 會是原始帳號; 否則詢問
if [ -n "${SUDO_USER:-}" ]; then
  REAL_USER="$SUDO_USER"
else
  read -rp "Enter the username to configure dotfiles for: " REAL_USER
fi
USER_HOME=$(eval echo "~$REAL_USER")
info "dotfiles 將套用至 $REAL_USER ($USER_HOME)"

# ─── dotfiles: 從 GitHub 抓 resources ───────────
BASE_URL="https://raw.githubusercontent.com/plotdb/setup/main/resources"

info "更新 /etc/bash.bashrc..."
wget -qO /etc/bash.bashrc "$BASE_URL/bash_profile"
ok "/etc/bash.bashrc 更新完成"

# ─── dotfiles: comment out PS1 in .bashrc ───────
comment_ps1() {
  local bashrc="$1"
  if [ -f "$bashrc" ]; then
    sed -i 's/^\(\s*PS1\)/#\1/' "$bashrc"
    ok "PS1 lines commented out in $bashrc"
  fi
}
comment_ps1 "$USER_HOME/.bashrc"
comment_ps1 "/home/$WEB_USER/.bashrc"

# ─── dotfiles: screenrc & vimrc ─────────────────
info "安裝 screenrc / vimrc..."
wget -qO "$USER_HOME/.screenrc" "$BASE_URL/screenrc"
wget -qO "$USER_HOME/.vimrc"    "$BASE_URL/vimrc"
chown "$REAL_USER:$REAL_USER" "$USER_HOME/.screenrc" "$USER_HOME/.vimrc"
ok "screenrc / vimrc 安裝完成"

# ─── dotfiles: vim-config ────────────────────────
if [ ! -d "$USER_HOME/.vim" ]; then
  info "clone vim-config..."
  git clone https://github.com/zbryikt/vim-config "$USER_HOME/.vim"
  chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.vim"
  ok "vim-config clone 完成"
else
  ok "$USER_HOME/.vim 已存在, 跳過"
fi

# ─── 12. crontab: 清 /tmp + certbot 自動更新 ──
info "設定 crontab (清 /tmp、certbot renew)..."
EXISTING_CRON=$(crontab -l 2>/dev/null || true)
(
  echo "$EXISTING_CRON" | grep -v 'certbot renew\|find /tmp' || true
  cat <<'CRON'
0 0 * * * find /tmp/ -type f -mtime +30 -exec rm -f {} \;
0 0 * * * certbot renew --post-hook "/bin/systemctl reload nginx"
CRON
) | crontab -
ok "crontab 設定完成"

# ─────────────────────────────────────────────
echo ""
ok "========== 初始化完成 =========="
echo ""
echo "  Node.js : $(node --version)"
echo "  npm     : $(npm --version)"
echo "  lsc     : $(lsc --version 2>/dev/null || echo 'not found')"
echo "  psql    : $(psql --version)"
echo "  certbot : $(certbot --version 2>&1)"
echo ""
warn "記得手動完成:"
echo "  1. 將 id_rsa.pub 加入 VM 的 SSH authorized_keys"
echo "  2. 若需要自訂 sshd port, 修改 /etc/ssh/sshd_config 並 restart sshd"
