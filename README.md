# Debian-GeoIP-Block with IpTables and Ipset.

I run a couple of VPS machines on Linode and HostZinger, and was tired of China, India, and some of the other countries banging on the door / trying to brute force some of my services.

Yes I run fail2ban, and it does a pretty good, but I wanted to just go ahead and straight up block some of the worst offenders.

To use the script, you need to make sure you have the required packages installed, to install them run:

sudo apt-get install -y ipset iptables-persistent netfilter-persistent ipset-persistent wget

After that, put the service file in /etc/systemd/system

The timer file also goes in /etc/systemd/system

You can then install the script in /usr/local/sbin, and chmod +x it

*****FIRST TIME RUN*****

Run the script /usr/local/sbin/update-geoip-blocks.sh ... that will create the firewall rules, download the files, etc 
After the script is run, update systemd with the new service and timer file:

sudo systemctl daemon-reload
sudo systemctl enable --now update-geoip-blocks.timer

Each rule logs with the prefix GEO4 or GEO6, so you can easily run:  journalctl -k -g GEO4 --no-pager -o short-precise 
That will show you ip's that have been blocked and what port they are trying to get in on.



Hopefully this helps someone.
