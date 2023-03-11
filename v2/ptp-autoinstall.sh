#! /bin/bash

. unattend.conf
cp fullchain.pem /etc/letsencrypt/live/$panelurl/fullchain.pem
cp privkey.pem /etc/letsencrypt/live/$panelurl/privkey.pem
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash
apt update
apt-add-repository --force-yes universe
apt -y install php8.1 php8.1-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} nginx tar unzip git redis-server mariadb-server
mysql --user=root <<_EOF_
UPDATE mysql.user SET Password=PASSWORD('$dbpwd') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
_EOF_
systemctl stop mariadb.service
echo -e "[mysqld]\nbinlog_format=ROW\ndefault-storage-engine=innodb\ninnodb_autoinc_lock_mode=2\nbind_address=0.0.0.0\nwsrep_on=ON\nwsrep_provider = /usr/lib/galera/libgalera_smm.so\nwsrep_cluster_name=\"$gcname\"\nwsrep_cluster_address=\"$gcomm\"\nwsrep_sst_method=rsync\nwsrep_node_address=\"$ipaddr\"\nwsrep_node_name=\"$hostname\"\n" > /etc/mysql/conf.d/galera.cnf
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
galera_new_cluster
mysql --user=root --password="$dbpwd" <<_EOF_
CREATE DATABASE panel;
CREATE USER 'pterodactyl'@'%' IDENTIFIED BY '$dbpwd' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'%' WITH GRANT OPTION;
_EOF_
cp .env.example .env 
yes | composer install --no-dev --optimize-autoloader 
php artisan key:generate --force
php artisan p:environment:setup --author=$eggemail --url=https://$panelurl --timezone=$timezone --cache=$cache --session=$session --queue=$queue --redis-host=$redishost --redis-pass=null --redis-port=$redisport --settings-ui=$settingsui --telemetry=
php artisan p:environment:database --host=$ipaddr --port=3306 --database=$dbname --username=$dbuser --password=$dbpwd
php artisan migrate --seed --force
php artisan p:user:make --email=$email --username=$username --name-first=$firstname --name-last=$lastname --password=$password --admin=$admin
chown -R www-data:www-data /var/www/pterodactyl/*
echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" >> /etc/crontab
echo -e "[Unit]\nDescription=Pterodactyl Queue Worker\nAfter=redis-server.service\n[Service]\nUser=www-data\nGroup=www-data\nRestart=always\nExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3\nStartLimitInterval=180\nStartLimitBurst=30\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target" >> /etc/systemd/system/pteroq.service
systemctl enable --now redis-server
systemctl enable --now pteroq
rm /etc/nginx/sites-enabled/default


echo -e "server_tokens off;\nserver {\n    listen 80;\n    server_name $panelurl;\n    return 301 https://\$server_name\$request_uri;\n}\nserver {\n    listen 443 ssl http2;\n    server_name $panelurl;\n    root /var/www/pterodactyl/public;\n    index index.php;\n    access_log /var/log/nginx/pterodactyl.app-access.log;\n    error_log  /var/log/nginx/pterodactyl.app-error.log error;\n        client_max_body_size 100m;\n    client_body_timeout 120s;\n    sendfile off;\n    ssl_certificate /etc/letsencrypt/live/$panelurl/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/$panelurl/privkey.pem;\n    ssl_session_cache shared:SSL:10m;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_ciphers \"ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384\";\n    ssl_prefer_server_ciphers on;\n    # See https://hstspreload.org/ before uncommenting the line below.\n    # add_header Strict-Transport-Security \"max-age=15768000; preload;\";\n    add_header X-Content-Type-Options nosniff;\n    add_header X-XSS-Protection \"1; mode=block\";\n    add_header X-Robots-Tag none;\n    add_header Content-Security-Policy \"frame-ancestors 'self'\";\n    add_header X-Frame-Options DENY;\n    add_header Referrer-Policy same-origin;\n    location / {\n        try_files \$uri \$uri/ /index.php?\$query_string;\n    }\n    location ~ \.php$ {\n        fastcgi_split_path_info ^(.+\.php)(/.+)$;\n        fastcgi_pass unix:/run/php/php8.1-fpm.sock;\n        fastcgi_index index.php;\n        include fastcgi_params;\n        fastcgi_param PHP_VALUE \"upload_max_filesize = 100M \n post_max_size=100M\";\n        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;\n        fastcgi_param HTTP_PROXY "";\n        fastcgi_intercept_errors off;\n        fastcgi_buffer_size 16k;\n        fastcgi_buffers 4 16k;\n        fastcgi_connect_timeout 300;\n        fastcgi_send_timeout 300;\n        fastcgi_read_timeout 300;\n        include /etc/nginx/fastcgi_params;\n    }\n    location ~ /\.ht {\n        deny all;\n    }\n}" > /etc/nginx/sitess-available/pterodactyl.conf
ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
echo "Fully completed."
