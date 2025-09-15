#!/bin/bash
# Pyrodactyl Installer with UX Loading Animations
# Debian 12
# Author: Afodene

set -e

spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

echo "==> Welcome to Pyrodactyl Auto Installer!"

# --- Prompt user ---
read -p "Enter your panel domain (e.g., panel.example.com): " APP_URL
read -p "Enter your MariaDB root password: " ROOT_DB_PASS
read -p "Enter Pyrodactyl DB username: " DB_USER
read -sp "Enter Pyrodactyl DB password: " DB_PASS
echo
DB_NAME="pyrodactyl"
APP_DIR="/var/www/pyrodactyl"

# --- Updating system ---
echo -n "Updating system..."
(apt update -y && apt upgrade -y) & spinner
echo "Done ✅"

# --- Install dependencies ---
echo -n "Installing dependencies..."
(apt install -y software-properties-common curl wget git unzip sudo gnupg lsb-release ca-certificates) & spinner
echo "Done ✅"

# --- Install PHP 8.2 ---
echo -n "Installing PHP 8.2 and extensions..."
(apt install -y php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-xml php8.2-curl php8.2-mbstring php8.2-bcmath php8.2-gd php8.2-zip php8.2-intl php8.2-readline php8.2-bz2) & spinner
echo "Done ✅"

# --- Install MariaDB ---
echo -n "Installing MariaDB..."
(apt install -y mariadb-server mariadb-client) & spinner
echo "Done ✅"

echo -n "Securing MariaDB..."
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_DB_PASS';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF
echo "Done ✅"

echo -n "Creating database and user..."
mysql -u root -p"$ROOT_DB_PASS" <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
echo "Done ✅"

# --- Nginx ---
echo -n "Installing Nginx..."
(apt install -y nginx) & spinner
echo "Done ✅"

# --- Redis ---
echo -n "Installing Redis..."
(apt install -y redis-server) & spinner
echo "Done ✅"

# --- Node.js ---
echo -n "Installing Node.js..."
(curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt install -y nodejs) & spinner
echo "Done ✅"

# --- Composer ---
echo -n "Installing Composer..."
(curl -sS https://getcomposer.org/installer | php && mv composer.phar /usr/local/bin/composer) & spinner
echo "Done ✅"

# --- Clone Pyrodactyl ---
echo -n "Cloning Pyrodactyl repository..."
(git clone https://github.com/pyrodactyl/pyrodactyl.git $APP_DIR) & spinner
echo "Done ✅"

cd $APP_DIR

echo -n "Installing PHP dependencies..."
(composer install --no-dev --optimize-autoloader) & spinner
echo "Done ✅"

echo -n "Configuring .env..."
cp .env.example .env
sed -i "s|DB_DATABASE=panel|DB_DATABASE=$DB_NAME|g" .env
sed -i "s|DB_USERNAME=panel|DB_USERNAME=$DB_USER|g" .env
sed -i "s|DB_PASSWORD=secret|DB_PASSWORD=$DB_PASS|g" .env
sed -i "s|APP_URL=http://panel.example.com|APP_URL=http://$APP_URL|g" .env
echo "Done ✅"

echo -n "Generating application key..."
(php artisan key:generate) & spinner
echo "Done ✅"

echo -n "Running migrations..."
(php artisan migrate --seed) & spinner
echo "Done ✅"

echo -n "Setting permissions..."
(chown -R www-data:www-data $APP_DIR && chmod -R 755 $APP_DIR) & spinner
echo "Done ✅"

# --- Queue Worker ---
echo -n "Setting up queue worker..."
cat <<EOL >/etc/systemd/system/pyro-queue.service
[Unit]
Description=Pyrodactyl Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/php artisan queue:work --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOL
systemctl daemon-reload
systemctl enable pyro-queue
systemctl start pyro-queue
echo "Done ✅"

# --- Nginx config ---
echo -n "Configuring Nginx..."
cat <<EOL >/etc/nginx/sites-available/pyrodactyl.conf
server {
    listen 80;
    server_name $APP_URL;

    root $APP_DIR/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

ln -s /etc/nginx/sites-available/pyrodactyl.conf /etc/nginx/sites-enabled/
(nginx -t && systemctl restart nginx) & spinner
echo "Done ✅"

# --- SSL ---
read -p "Do you want to enable SSL with Let's Encrypt? (y/n): " SSL_CHOICE
if [[ "$SSL_CHOICE" =~ ^[Yy]$ ]]; then
    echo -n "Installing Certbot and enabling SSL..."
    (apt install -y certbot python3-certbot-nginx && certbot --nginx -d $APP_URL --non-interactive --agree-tos -m admin@$APP_URL) & spinner
    echo "Done ✅"
fi

echo "🎉 Installation complete! Visit http://$APP_URL"
