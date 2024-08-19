#!/bi#!/bin/bash

set -e

# Variables globales
PANEL_DOMAIN="panel.yourdomain.com"
NODE_DOMAIN="node.yourdomain.com"
PHPMYADMIN_DOMAIN="phpmyadmin.yourdomain.com"
MYSQL_ROOT_PASSWORD="your_mysql_root_password"
PTERODACTYL_DB_PASSWORD="your_pterodactyl_db_password"
EMAIL="admin@yourdomain.com"
LOG_PATH="/var/log/pterodactyl-installer.log"

# Función para mostrar mensajes
output() {
  echo -e "$@"
}

# Verifica si curl está instalado
if ! [ -x "$(command -v curl)" ]; then
  output "* curl es requerido para ejecutar este script."
  output "* instálalo usando apt (Debian y derivados) o yum/dnf (CentOS)"
  exit 1
fi

# Función para la instalación del panel
install_panel() {
  output "* Instalando el panel Pterodactyl..."
  
  apt update && apt upgrade -y
  apt install -y curl sudo software-properties-common gnupg apt-transport-https ca-certificates lsb-release ufw
  
  # Configurar firewall
  ufw allow OpenSSH
  ufw allow 'Nginx Full'
  ufw --force enable
  
  # Instalar dependencias
  curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
  apt update && apt install -y nodejs mariadb-server redis-server nginx certbot python3-certbot-nginx composer unzip
  
  # Configurar MariaDB
  mysql_secure_installation <<EOF

y
$MYSQL_ROOT_PASSWORD
$MYSQL_ROOT_PASSWORD
y
y
y
y
EOF

  # Crear base de datos y usuario para Pterodactyl
  mysql -u root -p$MYSQL_ROOT_PASSWORD -e "CREATE DATABASE panel;"
  mysql -u root -p$MYSQL_ROOT_PASSWORD -e "CREATE USER 'pterodactyl'@'localhost' IDENTIFIED BY '$PTERODACTYL_DB_PASSWORD';"
  mysql -u root -p$MYSQL_ROOT_PASSWORD -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'localhost' WITH GRANT OPTION;"
  mysql -u root -p$MYSQL_ROOT_PASSWORD -e "FLUSH PRIVILEGES;"
  
  # Instalar Pterodactyl Panel
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl
  curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/
  cp .env.example .env
  composer install --no-dev --optimize-autoloader
  php artisan key:generate --force
  php artisan p:environment:database --host=127.0.0.1 --port=3306 --database=panel --username=pterodactyl --password=$PTERODACTYL_DB_PASSWORD
  php artisan migrate --seed --force
  php artisan queue:restart
  
  # Configurar Nginx para el panel
  cat <<EOT > /etc/nginx/sites-available/$PANEL_DOMAIN.conf
server {
    listen 80;
    server_name $PANEL_DOMAIN;
    root /var/www/pterodactyl/public;
    index index.php index.html index.htm;
    access_log /var/log/nginx/pterodactyl_access.log;
    error_log  /var/log/nginx/pterodactyl_error.log error;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php7.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOT

  ln -s /etc/nginx/sites-available/$PANEL_DOMAIN.conf /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  # Configurar Certbot para el panel
  certbot --nginx -d $PANEL_DOMAIN --non-interactive --agree-tos -m $EMAIL
  
  output "* Panel Pterodactyl instalado y configurado en $PANEL_DOMAIN"
}

# Función para la instalación de Wings
install_wings() {
  output "* Instalando Wings..."
  
  # Instalar Docker
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  apt update && apt install -y docker-ce docker-ce-cli containerd.io
  
  # Descargar y configurar Wings
  mkdir -p /etc/pterodactyl
  cd /etc/pterodactyl
  curl -Lo wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
  chmod +x wings
  
  # Crear archivo de configuración de Wings
  cat <<EOT > /etc/pterodactyl/config.yml
# Configuración de Wings
EOT

  # Configurar Wings como servicio
  cat <<EOT > /etc/systemd/system/wings.service
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/etc/pterodactyl/wings
Restart=on-failure
StartLimitInterval=600

[Install]
WantedBy=multi-user.target
EOT

  systemctl enable wings --now

  # Configurar Nginx para Wings (Nodo)
  cat <<EOT > /etc/nginx/sites-available/$NODE_DOMAIN.conf
server {
    listen 80;
    server_name $NODE_DOMAIN;

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOT

  ln -s /etc/nginx/sites-available/$NODE_DOMAIN.conf /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  # Configurar Certbot para el Nodo
  certbot --nginx -d $NODE_DOMAIN --non-interactive --agree-tos -m $EMAIL

  output "* Wings instalado y configurado en $NODE_DOMAIN"
}

# Función para la instalación de phpMyAdmin
install_phpmyadmin() {
  output "* Instalando phpMyAdmin..."
  
  apt install -y phpmyadmin
  
  # Configurar Nginx para phpMyAdmin
  cat <<EOT > /etc/nginx/sites-available/$PHPMYADMIN_DOMAIN.conf
server {
    listen 80;
    server_name $PHPMYADMIN_DOMAIN;
    root /usr/share/phpmyadmin;
    index index.php index.html index.htm;
    access_log /var/log/nginx/phpmyadmin_access.log;
    error_log  /var/log/nginx/phpmyadmin_error.log error;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php7.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOT

  ln -s /etc/nginx/sites-available/$PHPMYADMIN_DOMAIN.conf /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  # Configurar Certbot para phpMyAdmin
  certbot --nginx -d $PHPMYADMIN_DOMAIN --non-interactive --agree-tos -m $EMAIL

  output "* phpMyAdmin instalado y configurado en $PHPMYADMIN_DOMAIN"
}

# Función de bienvenida
welcome() {
  output "\nBienvenido al instalador de Pterodactyl, Wings y phpMyAdmin\n"
}

# Menú principal
menu() {
  done=false
  while [ "$done" == false ]; do
    options=(
      "Instalar el Panel Pterodactyl"
      "Instalar Wings"
      "Instalar phpMyAdmin"
      "Instalar todo"
    )

    actions=(
      "install_panel"
      "install_wings"
      "install_phpmyadmin"
      "install_panel;install_wings;install_phpmyadmin"
    )

    output "¿Qué te gustaría hacer?"

    for i in "${!options[@]}"; do
      output "[$i] ${options[$i]}"
    done

    echo -n "* Ingresa el número de la opción que deseas: "
    read -r action

    if [[ "$action" =~ ^[0-3]$ ]]; then
      done=true
      IFS=";" read -r i1 i2 <<<"${actions[$action]}"
      $i1
      if [[ -n $i2 ]]; then $i2; fi
    else
      output "* Opción inválida. Por favor, elige una opción válida."
    fi
  done
}

# Inicio del script
welcome
menu
