#/bin/sh

sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ecsx3583
sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ectt1095
sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ecss1095

chown -R www-data:www-data /var/www/nabovarme/sms_spool
apachectl -D FOREGROUND
