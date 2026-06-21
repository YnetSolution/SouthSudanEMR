#Configure Sudo to allow docker commands without a password
sudo visudo
username ALL=(ALL) NOPASSWD: /usr/bin/docker

#add user to docker group
sudo usermod -aG docker $USER

#add docker script also as cron job to log for troubleshooting
* * * * * /opt/ssemr/docker_test.sh

