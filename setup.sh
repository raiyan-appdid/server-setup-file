#!/bin/bash
#
# Automated LAMP-style server setup for Laravel/PHP hosting
# Based on: "Setting Up a Server for Hosting any Web Application" (Raiyan Memon)
#
# Usage (on a fresh Ubuntu droplet, as root):
#   curl -fsSL https://your-domain.example.com/setup.sh -o setup.sh
#   bash setup.sh
#
# This script is INTERACTIVE for passwords (per your choice) but automates
# every command from the guide. Run it once on a fresh server.

set -e  # exit immediately if any command fails

# ---------- Helper functions ----------
info()  { echo -e "\033[1;34m[INFO]\033[0m $1"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

# ---------- Pre-flight checks ----------
if [ "$EUID" -ne 0 ]; then
  err "Please run this script as root (e.g. via sudo or as the droplet's root user)."
  exit 1
fi

if [ ! -f /etc/os-release ] || ! grep -qi ubuntu /etc/os-release; then
  warn "This script is written for Ubuntu. Continuing anyway, but things may differ on other distros."
fi

echo ""
echo "=================================================="
echo "  Automated Web Server Setup (Apache + MySQL + PHP)"
echo "=================================================="
echo ""

# ---------- Step 1: Update system ----------
info "Step 1/10: Updating package lists..."
apt update -y
ok "System updated."

# ---------- Step 2: Create user ----------
info "Step 2/10: Create a new sudo user"
read -rp "Enter a username to create: " NEW_USER

if id "$NEW_USER" &>/dev/null; then
  warn "User '$NEW_USER' already exists. Skipping creation."
else
  # adduser is interactive (asks for password + GECOS fields) — that matches
  # your choice of prompting interactively rather than auto-generating.
  adduser "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
  ok "User '$NEW_USER' created and added to sudo group."
fi

# ---------- Step 3: Apache ----------
info "Step 3/10: Installing Apache..."
apt install -y apache2

info "Configuring firewall for Apache + SSH..."
ufw allow 'Apache' || true
ufw allow OpenSSH || true
ufw allow ssh || true
# Note: 'ufw enable' is intentionally left commented out — enabling the
# firewall non-interactively can lock you out if rules aren't right yet.
# Uncomment the next line once you've verified SSH access works:
# yes | ufw enable

a2enmod proxy proxy_http
a2enmod rewrite
systemctl restart apache2
systemctl enable apache2
ok "Apache installed, modules enabled, firewall rules added."
systemctl status apache2 --no-pager || true

# ---------- Step 4: MySQL ----------
info "Step 4/10: Installing MySQL server..."
apt install -y mysql-server

echo ""
echo "MySQL setup: we'll create a MySQL user matching '$NEW_USER'."
read -rsp "Enter a password for this MySQL user: " MYSQL_USER_PASS
echo ""
read -rsp "Confirm password: " MYSQL_USER_PASS_CONFIRM
echo ""

if [ "$MYSQL_USER_PASS" != "$MYSQL_USER_PASS_CONFIRM" ]; then
  err "Passwords did not match. Re-run the script to try again."
  exit 1
fi

mysql <<EOF
CREATE USER IF NOT EXISTS '${NEW_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_USER_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${NEW_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
ok "MySQL user '$NEW_USER' created with full privileges."

# ---------- Step 5: PHP ----------
info "Step 5/10: Installing PHP and required extensions..."
apt install -y php libapache2-mod-php php-mysql php-xml php-dom

PHP_VERSION=$(php -v | head -n1)
ok "PHP installed: $PHP_VERSION"

# Prioritize index.php in Apache's directory index
DIR_CONF="/etc/apache2/mods-enabled/dir.conf"
if [ -f "$DIR_CONF" ] && ! grep -q "index.php" "$DIR_CONF"; then
  sed -i 's/DirectoryIndex index.html/DirectoryIndex index.php index.html/' "$DIR_CONF"
elif [ -f "$DIR_CONF" ]; then
  # ensure index.php is first even if the line already mentions it differently
  sed -i 's/DirectoryIndex \(.*\)/DirectoryIndex index.php \1/' "$DIR_CONF" 2>/dev/null || true
fi
systemctl restart apache2
ok "index.php prioritized in Apache directory index."

# ---------- Step 6: Composer + Node ----------
info "Step 6/10: Installing Composer and Node/npm..."
apt install -y composer npm
npm install -g mix 2>/dev/null || warn "Global 'mix' install skipped/failed (non-critical)."
ok "Composer and npm installed."

# ---------- Step 7: /var/www ownership ----------
info "Step 7/10: Setting ownership of /var/www to $NEW_USER..."
mkdir -p /var/www
chown -R "$NEW_USER":"$NEW_USER" /var/www
ok "/var/www is now owned by $NEW_USER."

# ---------- Step 8: Git + SSH key for GitHub ----------
info "Step 8/10: Configuring Git and generating an SSH key for $NEW_USER..."
read -rp "Enter the Git user.name to configure: " GIT_NAME
read -rp "Enter the Git user.email to configure: " GIT_EMAIL

USER_HOME="/home/${NEW_USER}"
SSH_DIR="${USER_HOME}/.ssh"
KEY_PATH="${SSH_DIR}/id_rsa"

sudo -u "$NEW_USER" git config --global user.name "$GIT_NAME"
sudo -u "$NEW_USER" git config --global user.email "$GIT_EMAIL"

if [ ! -f "$KEY_PATH" ]; then
  sudo -u "$NEW_USER" mkdir -p "$SSH_DIR"
  sudo -u "$NEW_USER" ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N "" -q
  ok "SSH key generated at $KEY_PATH"
else
  warn "SSH key already exists at $KEY_PATH, skipping generation."
fi

# ---------- Step 9: Verify GitHub SSH access + clone repo ----------
echo ""
echo "=================================================="
echo "  Step 9/10: GitHub SSH verification"
echo "=================================================="
echo ""
echo "Your public SSH key (add this to GitHub: Settings > SSH and GPG keys > New SSH key):"
echo "--------------------------------------------------"
cat "${KEY_PATH}.pub"
echo "--------------------------------------------------"
echo ""

# Make sure github.com's host key is trusted so the SSH test doesn't hang
# on an interactive "are you sure you want to continue connecting?" prompt.
sudo -u "$NEW_USER" mkdir -p "$SSH_DIR"
sudo -u "$NEW_USER" ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null || warn "ssh-keyscan failed — host key verification may prompt interactively."
chown "$NEW_USER":"$NEW_USER" "${SSH_DIR}/known_hosts" 2>/dev/null || true

GITHUB_VERIFIED=false

while [ "$GITHUB_VERIFIED" = false ]; do
  read -rp "Have you added the key above to your GitHub account? (y/n): " ADDED_KEY

  if [[ ! "$ADDED_KEY" =~ ^[Yy] ]]; then
    warn "Okay — add the key to GitHub, then press Enter to continue."
    read -rp "Press Enter once it's added..." _
  fi

  info "Testing SSH authentication against GitHub..."
  # GitHub's SSH test never grants a real shell — it always replies and
  # closes the connection. A successful auth includes "successfully
  # authenticated" in stderr; that's the reliable signal to check for.
  SSH_TEST_OUTPUT=$(sudo -u "$NEW_USER" ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no git@github.com 2>&1 || true)

  if echo "$SSH_TEST_OUTPUT" | grep -qi "successfully authenticated"; then
    ok "GitHub SSH authentication verified for $NEW_USER."
    GITHUB_VERIFIED=true
  else
    err "Could not verify SSH access to GitHub. GitHub responded with:"
    echo "    $SSH_TEST_OUTPUT"
    warn "Make sure you copied the FULL key (including 'ssh-rsa' at the start) into GitHub."
    read -rp "Try again? (y/n): " RETRY
    if [[ ! "$RETRY" =~ ^[Yy] ]]; then
      err "Skipping repo clone — you can clone manually later with:"
      echo "    su - ${NEW_USER}"
      echo "    cd /var/www && git clone <your-repo-ssh-url>"
      break
    fi
  fi
done

CLONE_PATH=""
APP_TYPE=""

if [ "$GITHUB_VERIFIED" = true ]; then
  echo ""
  read -rp "Enter the GitHub SSH clone URL (e.g. git@github.com:user/repo.git): " REPO_URL
  REPO_NAME=$(basename "$REPO_URL" .git)
  CLONE_PATH="/var/www/${REPO_NAME}"

  info "Cloning into ${CLONE_PATH}..."
  if sudo -u "$NEW_USER" git clone "$REPO_URL" "$CLONE_PATH"; then
    ok "Repository cloned to ${CLONE_PATH}."
  else
    err "git clone failed. Check the repo URL and try cloning manually later:"
    echo "    su - ${NEW_USER}"
    echo "    git clone ${REPO_URL} ${CLONE_PATH}"
    CLONE_PATH=""
  fi
fi

if [ -n "$CLONE_PATH" ]; then

  # ---------- Step 10: Framework-specific setup ----------
  echo ""
  echo "=================================================="
  echo "  Step 10/10: Application setup"
  echo "=================================================="
  echo ""
  echo "What type of application is this?"
  echo "  1) Laravel"
  echo "  2) Next.js"
  echo "  3) Skip (I'll set it up manually)"
  read -rp "Enter 1, 2, or 3: " APP_CHOICE

  case "$APP_CHOICE" in
    1)
      APP_TYPE="Laravel"
      info "Running Laravel setup in ${CLONE_PATH}..."

      sudo -u "$NEW_USER" bash -c "cd '${CLONE_PATH}' && composer install --ignore-platform-reqs --no-interaction --prefer-dist" || warn "composer install failed — check PHP/extension errors and re-run manually in ${CLONE_PATH}."

      if [ -f "${CLONE_PATH}/.env.example" ] && [ ! -f "${CLONE_PATH}/.env" ]; then
        sudo -u "$NEW_USER" cp "${CLONE_PATH}/.env.example" "${CLONE_PAT1H}/.env"
        ok ".env created from .env.example — edit it with your DB credentials before going further."
      fi

      sudo -u "$NEW_USER" bash -c "cd '${CLONE_PATH}' && npm install" || warn "npm install failed — check Node version and re-run manually in ${CLONE_PATH}."

    # ask the user whether to run npm run production or npm run build
      read -rp "Run 'npm run production' (1) or 'npm run build' (2)? [1/2]: " NPM_BUILD_CHOICE
      case "$NPM_BUILD_CHOICE" in
        1)
          sudo -u "$NEW_USER" bash -c "cd '${CLONE_PATH}' && npm run production" || warn "npm run production failed — check for missing env vars/config and re-run manually in ${CLONE_PATH}."
          ;;
        2)
          sudo -u "$NEW_USER" bash -c "cd '${CLONE_PATH}' && npm run build" || warn "npm run build failed — check for missing env vars/config and re-run manually in ${CLONE_PATH}."
          ;;
        *)
          warn "Skipping npm build step. You can run it manually later in ${CLONE_PATH}."
          ;;
      esac

      sudo -u "$NEW_USER" bash -c "cd '${CLONE_PATH}' && php artisan key:generate" || warn "artisan key:generate failed — run it manually after configuring .env."

      sudo -u "$NEW_USER" chmod -R 775 "${CLONE_PATH}/storage" "${CLONE_PATH}/bootstrap/cache" 2>/dev/null || true

      ok "Laravel dependencies installed. Remember to configure .env and run migrations:"
      echo "    cd ${CLONE_PATH} && php artisan migrate"
      ;;
    2)
      APP_TYPE="Next.js"
      info "Running Next.js setup in ${CLONE_PATH}..."

      sudo -u "$NEW_USER" bash -c "cd '${CLONE_PATH}' && npm install" || warn "npm install failed — check Node version and re-run manually in ${CLONE_PATH}."
      sudo -u "$NEW_USER" bash -c "cd '${CLONE_PATH}' && npm run build" || warn "npm run build failed — check for missing env vars/config and re-run manually in ${CLONE_PATH}."

      ok "Next.js dependencies installed and built. Start it with:"
      echo "    cd ${CLONE_PATH} && npm run start"
      echo "    (consider running this under pm2 or a systemd service to keep it alive)"
      ;;
    *)
      warn "Skipping framework-specific setup. Repo is at ${CLONE_PATH}."
      ;;
  esac
fi

# ---------- Done ----------
SERVER_IP=$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')

echo ""
echo "=================================================="
echo "  Setup complete!"
echo "=================================================="
echo ""
echo "User created:        $NEW_USER (sudo + MySQL access)"
echo "Apache:               running, visit http://${SERVER_IP}"
echo "MySQL user:           $NEW_USER"
echo "PHP:                  $PHP_VERSION"
echo "/var/www owner:       $NEW_USER"
if [ -n "$CLONE_PATH" ]; then
  echo "Repo cloned to:       $CLONE_PATH"
fi
if [ -n "$APP_TYPE" ]; then
  echo "Application type:     $APP_TYPE"
fi
echo ""
echo "Next steps:"
if [ "$APP_TYPE" = "Laravel" ]; then
  echo "  1. Edit ${CLONE_PATH}/.env with your real DB credentials."
  echo "  2. cd ${CLONE_PATH} && php artisan migrate"
  echo "  3. Point an Apache vhost at ${CLONE_PATH}/public"
elif [ "$APP_TYPE" = "Next.js" ]; then
  echo "  1. cd ${CLONE_PATH} && npm run start (or set up pm2/systemd)"
  echo "  2. Configure Apache as a reverse proxy to the Next.js port (default 3000)"
else
  echo "  1. su - ${NEW_USER}"
  echo "  2. cd /var/www && git clone <your-repo-ssh-url> (if not already cloned above)"
fi
echo ""