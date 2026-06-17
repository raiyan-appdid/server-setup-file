
set -e  # exit immediately if any command fails

info()  { echo -e "\033[1;34m[INFO]\033[0m $1"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

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
info "Step 1/8: Updating package lists..."
apt update -y
ok "System updated."

# ---------- Step 2: Create user ----------
info "Step 2/8: Create a new sudo user"
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
info "Step 3/8: Installing Apache..."
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
info "Step 4/8: Installing MySQL server..."
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
info "Step 5/8: Installing PHP and required extensions..."
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
info "Step 6/8: Installing Composer and Node/npm..."
apt install -y composer npm
npm install -g mix 2>/dev/null || warn "Global 'mix' install skipped/failed (non-critical)."
ok "Composer and npm installed."

# ---------- Step 7: /var/www ownership ----------
info "Step 7/8: Setting ownership of /var/www to $NEW_USER..."
mkdir -p /var/www
chown -R "$NEW_USER":"$NEW_USER" /var/www
ok "/var/www is now owned by $NEW_USER."

# ---------- Step 8: Git + SSH key for GitHub ----------
info "Step 8/8: Configuring Git and generating an SSH key for $NEW_USER..."
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
echo ""
echo "Your public SSH key (add this to GitHub: Settings > SSH and GPG keys):"
echo "--------------------------------------------------"
cat "${KEY_PATH}.pub"
echo "--------------------------------------------------"
echo ""
echo "Next steps:"
echo "  1. Copy the SSH key above into GitHub."
echo "  2. su - ${NEW_USER}"
echo "  3. cd /var/www && git clone <your-repo-ssh-url>"
echo ""