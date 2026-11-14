#!/bin/bash
   
    # VARIABLES
SCORING_USER=$1
OUR_USER=$2
BACKUP_DIR=$3

# Make backups
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

    # CHECK ARGS
if [[ -n "$OUR_USER" && -n "$SCORING_USER" && -n "$BACKUP_DIR"]]; then
    echo "starting script..."
else
    echo "DEFINE OUR_USER, SCORING_USER, and BACKUP_DIR"
    exit 1
fi

mkdir -p "$3"
for p in /var/www /etc /home /opt /root /usr/bin /bin /sbin /usr/sbin; do
  [[ -e "$p" ]] || continue
  mkdir -p "$3$(dirname "$p")"
  cp -a "$p" "$3$p"
done
chmod o-rwx $3


rm ~/.bash_history

    # Update
apt update -y 
apt upgrade -y || apt full-upgrade -y || exit 1
apt install wget -y
apt install vim -y
apt install ufw -y 
apt install busybox -y
apt install tmux -y
apt install auditd -y
apt install whowatch -y
apt install debsums -y
apt install ripgrep -y
apt install libapache2-mod-security2 -y
apt install modsecurity-crs -y
apt install nmap -y
apt install rkhunter -y
apt install foot -y 
apt install git -y

    # Disable guest login
mkdir -p /etc/lightdm/lightdm.conf.d
echo "[Seat:*]" > /etc/lightdm/lightdm.conf.d/50-no-guest.conf
echo "allow-guest=false" >> /etc/lightdm/lightdm.conf.d/50-no-guest.conf

    # Disable no password login
sed -i -e '/nopasswdlogin/d' /etc/group

    # Disable root login (Should not be relied on, there are ways to bypass)
    # True method is to append /nologin to 1st line in /etc/passwd
passwd -l root

    # Set permissions
chmod 644 /etc/passwd
chmod 600 /etc/shadow

    # FIREWALL CONFIG
ufw default deny incoming
ufw default deny outgoing

ufw allow in 22/tcp      # SSH
ufw allow in 53/udp      # DNS (UDP)
ufw allow in 53/tcp      # DNS (TCP)
ufw allow in 80/tcp      # HTTP
ufw allow in 443/tcp     # HTTPS

ufw allow out 22/tcp      # SSH
ufw allow out 53/udp      # DNS (UDP)
ufw allow out 3389/tcp    # RDP
ufw allow out 80/tcp      # HTTP
ufw allow out 443/tcp     # HTTPS
ufw allow out 21/tcp      # FTP
ufw allow out 990/tcp     # FTPS
ufw allow out 20/tcp      # FTP

ufw enable
ufw status numbered




    # HARDEN CRITCAL SERVICES

    # HARDEN SSHD
echo "PermitRootLogin no" >> /etc/ssh/sshd_config
echo "Protocol 2" >> /etc/ssh/sshd_config
echo "PublickeyAuthentication" >> /etc/ssh/sshd_config
    #SSH whitelist
sed -i -e '/PubkeyAuthentication yes/d' /etc/ssh/sshd_config
echo "PubkeyAuthentication no" >> /etc/ssh/sshd_config
#echo "AllowUsers $SCORING_USER $OUR_USER" >> /etc/ssh/sshd_config
chattr +i /etc/ssh/sshd_config
systemctl restart ssh
systemctl restart sshd


    # HARDEN APACHE
if command -v apache2 >/dev/null 2>&1; then
    chown -R root:root /etc/apache2
    chattr -i -R /etc/www
fi
    # HARDEN NGINX
    # HARDEN LIGHTTPD
    # HARDEN GUNICORN
    # HARDEN POSTGRESQL


    # GENERAL AUDITS, putting this after critical services bc I don't want to log stuff from this script
auditctl -w /etc/passwd -p wa -k users
auditctl -w /etc/group -p wa -k users
auditctl -w /etc/shadow -p rwa -k users
auditctl -w /etc/sudoers -p rwa -k users
auditctl -w /etc/sudoers.d -p rwa -k users

auditctl -w /etc/ssh -p wa -k ssh
auditctl -w /root/.ssh -p wa -k ssh
auditctl -w /home/*/.ssh -p wa -k ssh

auditctl -w /files -p wa -k ftp
auditctl -w /srv/ftp -p wa -k ftp
auditctl -w /var/ftp -p wa -k ftp

auditctl -w /var/www -p wa -k http
auditctl -w /etc/nginx -p wa -k http
auditctl -w /etc/apache2 -p wa -k http
auditctl -w /etc/httpd -p wa -k http
auditctl -w /etc/lighttpd -p wa -k http

auditctl -w /etc/crontab -wa -k cron
auditctl -w /etc/cron.* -wa -k cron
auditctl -w /etc/anacrontab -wa cron
auditctl -w /var/spool/cron -wa cron

touch ~/.log
echo "BASHRC:" >> ~/.log
cat .bashrc >> ~/.log
echo "Authorized keys:" >> ~/.log
ls -lah /home/*/.ssh/authorized_keys >> ~/.log
ls -lah /etc/ssh/authorized_keys.d/ >> ~/.log
ls -lah /var/www/.ssh/authorized_keys >> ~/.log
ls -lah /root/.ssh/authorized_keys >> ~/.log
echo "Authorized keys:" >> ~/.log
systemctl list-units --type=service --state=running --no-pager | grep "\.service" | cut -d " " -f 3


