    # mwp-pma link — domain={{DOMAIN}} expires={{EXPIRES_HUMAN}}
    location ^~ {{PMA_PATH}} {
        alias /usr/share/phpmyadmin/;
        index index.php;

        location ~ \.php$ {
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $request_filename;
            fastcgi_pass unix:/run/php/mwp-pma.sock;
        }
    }
