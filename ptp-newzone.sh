#!/bin/bash


echo "Please enter this node's ip address:"
read nodeaddr
echo "Please enter cluster gcomm string:"
read gcommaddr
echo "Please enter node hostname:"
read hostname
echo "Please enter galera clustername:"
read galeraname
echo "Please enter new database password:"
read dbpwd

apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

# Add additional repositories for PHP, Redis, and MariaDB
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

# Add Redis official APT repository
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

# MariaDB repo setup script can be skipped on Ubuntu 22.04
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

# Update repositories list
apt update
apt-add-repository --force-yes universe
apt -y install php8.1 php8.1-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} nginx tar unzip git redis-server mariadb-server
systemctl stop mariadb.service

mysql --user=root <<_EOF_
UPDATE mysql.user SET Password=PASSWORD('$dbpwd') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
_EOF_
echo -e "[mysqld]\nbinlog_format=ROW\ndefault-storage-engine=innodb\ninnodb_autoinc_lock_mode=2\nbind_address=0.0.0.0\nwsrep_on=ON\nwsrep_provider = /var/lib/galera/libgalera_smm.so\nwsrep_cluster_name=\"$galeraname\"\nwsrep_cluster_address=\"$gcommaddr\"\nwsrep_sst_method=rsync\nwsrep_node_address=\"$nodeaddr\"\nwsrep_node_name=\"$hostname\"\n" > /etc/mysql/conf.d/galera.cnf

curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
galera_new_cluster
mysql --user=root --password=$dbpwd <<_EOF_
CREATE DATABASE panel;
CREATE USER 'pterodactyl'@'%' IDENTIFIED BY '$dbpwd' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'%' WITH GRANT OPTION;
_EOF_
cp .env.example .env 
yes | composer install --no-dev --optimize-autoloader 
php artisan key:generate --force
php artisan p:environment:setup
php artisan p:environment:database
php artisan p:environment:mail
php artisan migrate --seed --force
php artisan p:user:make
chown -R www-data:www-data /var/www/pterodactyl/*
echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" >> /etc/crontab
echo -e "[Unit]\nDescription=Pterodactyl Queue Worker\nAfter=redis-server.service\n[Service]\nUser=www-data\nGroup=www-data\nRestart=always\nExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3\nStartLimitInterval=180\nStartLimitBurst=30\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target" >> /etc/systemd/pteroq.service
systemctl enable --now redis-server
systemctl enable --now pteroq.service
rm /etc/nginx/sites-enabled/default
echo "PLEASE CONFIGURE NGINX MANUALLY: https://pterodactyl.io/panel/1.0/webserver_configuration.html"
