#!/bin/bash

# Our first required argument to run this script is to specify the environment to run Lynx. The two
# accepted options are 'mainnet' or 'testnet'.

if [ "$1" = "mainnet" ]; then

	environment="mainnet"
	port="22566"
	rpcport="9332"
	lynxbranch="master"
	explorerbranch="master"
	lynxconfig=""
	explorer="https://explorer.getlynx.io/api/getblockcount"
	addresses="miner-addresses.txt"

else

	environment="testnet"
	port="44566"
	rpcport="19335"
	lynxbranch="new_validation_rules"
	explorerbranch="new-ui"
	lynxconfig="testnet=1"
	explorer="https://testnet.getlynx.io/api/getblockcount"
	addresses="miner-addresses-testnet.txt"

fi

BLUE='\033[94m'
GREEN='\033[32;1m'
YELLOW='\033[33;1m'
RED='\033[91;1m'
RESET='\033[0m'

print_info () {

	printf "$BLUE$1$RESET\n"
	sleep 1

}

print_success () {

	printf "$GREEN$1$RESET\n"
	sleep 1

}

print_warning () {

	printf "$YELLOW$1$RESET\n"
	sleep 1

}

print_error () {

	printf "$RED$1$RESET\n"
	sleep 1

}

detect_os () {

	# We are inspecting the local operating system and extracting the full name so we know the 
	# unique flavor. In the rest of the script we have various changes that are dedicated to
	# certain operating system versions.

	pretty_name=`cat /etc/os-release | egrep '^PRETTY_NAME=' | cut -d= -f2 -d'"'`
	version_id=`cat /etc/os-release | egrep '^VERSION_ID=' | cut -d= -f2 -d'"'`
	version=`cat /etc/os-release | egrep '^VERSION=' | cut -d= -f2 -d'"'`

	if [ -z "cat /proc/cpuinfo | grep 'Revision' | awk '{print $3}'" ]; then

		isPi="true"

	else

		isPi="false"

	fi

	print_success "The local operating system is '$pretty_name'."

	print_success "Build environment is '$environment'."

}

detect_ec2() {

	IsEC2="N"

    # This first, simple check will work for many older instance types.

    if [ -f /sys/hypervisor/uuid ]; then

		# File should be readable by non-root users.

		if [ `head -c 3 /sys/hypervisor/uuid` == "ec2" ]; then
			IsEC2="Y"
		fi

    # This check will work on newer m5/c5 instances, but only if you have root!

    elif [ -r /sys/devices/virtual/dmi/id/product_uuid ]; then

		# If the file exists AND is readable by us, we can rely on it.

		if [ `head -c 3 /sys/devices/virtual/dmi/id/product_uuid` == "EC2" ]; then
			IsEC2="Y"
		fi

    else

		# Fallback check of http://169.254.169.254/. If we wanted to be REALLY
		# authoritative, we could follow Amazon's suggestions for cryptographically
		# verifying their signature, see here:
		# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-identity-documents.html
		# but this is almost certainly overkill for this purpose (and the above
		# checks of "EC2" prefixes have a higher false positive potential, anyway).

		if $(curl -s -m 5 http://169.254.169.254/latest/dynamic/instance-identity/document | grep -q availabilityZone) ; then
			IsEC2="Y"
		fi
    fi

}

detect_vps () {

	detect_ec2
}

install_extras () {

	apt-get install cpulimit htop curl fail2ban -y &> /dev/null
	print_success "Cpulimit was installed."

	apt-get install automake autoconf pkg-config libcurl4-openssl-dev libjansson-dev libssl-dev libgmp-dev make g++ -y &> /dev/null
	print_success "Cpuminer was installed."

}

update_os () {

	apt-get update -y &> /dev/null 

	if [ "$isPi" = "true" ]; then

		# 'Raspbian GNU/Linux 9 (stretch)' would evaluate here.

		print_success "Raspbian was detected. You are using a Raspberry Pi. We love you."

		touch /boot/ssh

		print_success "SSH access was enabled by creating the SSH file in /boot."

		# Let's be sure this management script has the right permissions to operate properly.

		chmod 700 /root/LynxNodeBuilder/disableHDMI.sh

	fi

}

expand_swap () {

	# We are only modifying the swap amount for a Raspberry Pi device. In the future, other
	# environments will have their own place in the following conditional statement.

	if [ "$isPi" = "true" ]; then

		# On a Raspberry Pi 3, the default swap is 100MB. This is a little restrictive, so we are
		# expanding it to a full 1GB of swap. We don't usually touch too much swap but during the 
		# initial compile and build process, it does consume a good bit so lets provision this.

		sed -i 's/CONF_SWAPSIZE=100/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile

		print_success "Swap will be increased to 1GB on reboot."

	fi

}

reduce_gpu_mem () {

	# On the Pi, the default amount of gpu memory is set to be used with the GUI build. Instead 
	# we are going to set the amount of gpu memmory to a minimum due to the use of the Command
	# Line Interface (CLI) that we are using in this build. This means we don't have a GUI here,
	# we only use the CLI. So no need to allocate GPU ram to something that isn't being used. Let's 
	# assign the param below to the minimum value in the /boot/config.txt file.

	if [ "$isPi" = "true" ]; then

		# First, lets not assume that an entry doesn't already exist, so let's purge and preexisting
		# gpu_mem variables from the respective file.

		sed -i '/gpu_mem/d' /boot/config.txt

		# Now, let's append the variable and value to the end of the file.

		echo "gpu_mem=16" >> /boot/config.txt

		print_success "GPU memory was reduced to 16MB on reboot."

	fi

}

disable_bluetooth () {


	if [ "$isPi" = "true" ]; then

		# First, lets not assume that an entry doesn't already exist, so let's purge any preexisting
		# bluetooth variables from the respective file.

		sed -i '/pi3-disable-bt/d' /boot/config.txt

		# Now, let's append the variable and value to the end of the file.

		echo "dtoverlay=pi3-disable-bt" >> /boot/config.txt

		print_success "Bluetooth antenna was disabled on reboot."

		# Next, we remove the bluetooth package that was previously installed.

		apt-get remove pi-bluetooth -y &> /dev/null

		print_success "Bluetooth was uninstalled."

	fi

}

set_network () {

	ipaddr=$(ip route get 1 | awk '{print $NF;exit}')
	hhostname="lynx$(shuf -i 100000000-199999999 -n 1)"
	fqdn="$hhostname.getlynx.io"

	echo $hhostname > /etc/hostname && hostname -F /etc/hostname
	
	print_success "Setting the local host name to '$hhostname.'"

	echo $ipaddr $fqdn $hhostname >> /etc/hosts

}

set_wifi () {

	# The only time we want to set up the wifi is if the script is running on a Raspberry Pi. The
	# script should just skip over this step if we are on any OS other then Raspian. 

	if [ "$isPi" = "true" ]; then

		# Let's assume the files already exists, so we will delete them and start from scratch.

		rm -rf /boot/wpa_supplicant.conf
		rm -rf /etc/wpa_supplicant/wpa_supplicant.conf
		
		echo "

		ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
		update_config=1
		country=US

		network={
			ssid=\"Your network SSID\"
			psk=\"Your WPA/WPA2 security key\"
			key_mgmt=WPA-PSK
		}

		" >> /boot/wpa_supplicant.conf

		print_success ""
		print_success "Wifi configuration script was installed."
		print_success ""

	fi

}

set_accounts () {

	sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config

	ssuser="lynx"
	sspassword="lynx"

	adduser $ssuser --disabled-password --gecos "" && echo "$ssuser:$sspassword" | chpasswd

	adduser $ssuser sudo

	# We only need to lock the Pi account if this is a Raspberry Pi. Otherwise, ignore this step.

	if [ "$isPi" = "true" ]; then

		# Let's lock the pi user account, no need to delete it.

		usermod -L -e 1 pi

		# Let's print to the screen some helpful information for the user that might be watching
		# the install take place. This might prove insightful.

		print_success ""
		print_success "On a Raspberry Pi, the default user account is 'pi'. But this script has"
		print_success "locked that user account. Don't try to use it, it won't work. Yes, you"
		print_success "could reset it, but for simplicity, we recommend you use the newly created"
		print_success "user account for this LynxCI device. The new username is '$ssuser' and the"
		print_success "respective password is '$sspassword'. Be sure to change the password after"
		print_success "you log in for the first time."
		print_success ""

		# Display the message on the screen for 20 seconds.

		sleep 20

	fi
}

install_portcheck () {

	rm -rf /etc/profile.d/portcheck.sh

	echo "	#!/bin/bash

	BLUE='\033[94m'
	GREEN='\033[32;1m'
	RED='\033[91;1m'
	RESET='\033[0m'

	print_success () {

		printf \"\$GREEN\$1\$RESET\n\"

	}

	print_error () {

		printf \"\$RED\$1\$RESET\n\"

	}

	print_info () {

		printf \"\$BLUE\$1\$RESET\n\"

	}

	print_success \" Standby, checking connectivity...\"

	# When the build script runs, we know the lynxd port, but we don't know if after the node is 
	# built. So we are hardcoding the value here, so it can be checked in the future.

	port=\"$port\"
	rpcport=\"$rpcport\"

	if [ -z \"\$(netstat -an | grep \$port | grep -i listen)\" ]; then
	  app_reachable=\"false\"
	else
	  app_reachable=\"true\"
	fi

	if [ -z \"\$(netstat -an | grep \$rpcport | grep -i listen)\" ]; then
	  rpc_reachable=\"false\"
	else
	  rpc_reachable=\"true\"
	fi

	if ! pgrep -x \"lynxd\" > /dev/null; then

		block=\"being updated\"

	else

		if pgrep -x \"nginx\" > /dev/null; then
			block=\$(curl -s http://127.0.0.1/bc_api.php?request=getblockcount)
		else
			block=\$(curl -s http://127.0.0.1/api/getblockcount)
		fi

		block=\$(echo \$block | numfmt --grouping)

	fi

	print_success \"\"
	print_success \"\"
	print_success \"\"

	# This file really should not be downloaded over and over again. Instead, just copy the local
	# file in root to a dir in /home/lynx/ for self indexing.

	curl -s https://raw.githubusercontent.com/doh9Xiet7weesh9va9th/LynxNodeBuilder/master/logo.txt

	echo \"
 | To set up wifi, edit the /etc/wpa_supplicant/wpa_supplicant.conf file.      |
 '-----------------------------------------------------------------------------'
 | For local tools to play and learn, type 'sudo /root/lynx/src/lynx-cli help' |
 '-----------------------------------------------------------------------------'
 | LYNX RPC credentials for remote access are located in /root/.lynx/lynx.conf |
 '-----------------------------------------------------------------------------'\"

	if [ \"\$app_reachable\" = \"true\" ]; then

		print_success \"\"
		print_success \" Lynx port \$port is open.\"

	else

		print_success \"\"
		print_error \" Lynx port \$port is not open.\"

	fi

	if [ \"\$rpc_reachable\" = \"true\" ]; then

		print_success \"\"
		print_success \" Lynx RPC port \$rpcport is open.\"
		print_success \"\"

	else

		print_success \"\"
		print_error \" Lynx RPC port \$rpcport is not open.\"
		print_success \"\"

	fi

	if [ \"\$port\" = \"44566\" ]; then

		print_error \" This is a non-production 'testnet' environment of Lynx.\"
		print_success \"\"

	fi

	print_success \" Lot's of helpful videos about LynxCI are available at the Lynx FAQ. Visit \"
	print_success \" https://getlynx.io/faq/ for more information and help.\"
	print_success \"\"
	print_info \" The current block height on this Lynx node is \$block.\"
	print_success \"\"

	" > /etc/profile.d/portcheck.sh

	chmod 744 /etc/profile.d/portcheck.sh
	chown root:root /etc/profile.d/portcheck.sh

}

install_iquidusExplorer () {

	# Let's jump pack to the root directory, since we can't assume we know where we were.

	cd ~/

	# Let's not assume this is the first time this function is run, so let's purge the directory if
	# it already exists. This way if the power goes out during install, the build process can 
	# gracefully restart.

	rm -rf ~/LynxExplorer && rm -rf ~/.npm-global

	# We might need curl and some other dependencies so let's grab those now. It is also possible 
	# these packages might be used elsewhere in this script so installing them now is no problem.
	# The apt installed is smart, if the package is already installed, it will either attempt to 
	# upgrade the package or skip over the step. No harm done.

    apt-get install curl software-properties-common gcc g++ make -y &> /dev/null

    curl -sL https://deb.nodesource.com/setup_10.x | sudo -E bash -
    apt-get install nodejs -y &> /dev/null
    print_success "NodeJS was installed."

	npm install pm2 -g
	print_success "PM2 was installed."

	git clone -b $explorerbranch https://github.com/doh9Xiet7weesh9va9th/LynxExplorer.git
	print_success "Block Explorer was installed."
	
	cd /root/LynxExplorer/ && npm install --production

	# We need to update the json file in the LynxExplorer node app with the lynxd RPC access
	# credentials for this device. Since they are created dynamically each time, we just do
	# find and replace in the json file.

	sed -i "s/9332/${rpcport}/g" /root/LynxExplorer/settings.json
	sed -i "s/__HOSTNAME__/x${fqdn}/g" /root/LynxExplorer/settings.json
	sed -i "s/__MONGO_USER__/x${rrpcuser}/g" /root/LynxExplorer/settings.json
	sed -i "s/__MONGO_PASS__/x${rrpcpassword}/g" /root/LynxExplorer/settings.json
	sed -i "s/__LYNXRPCUSER__/${rrpcuser}/g" /root/LynxExplorer/settings.json
	sed -i "s/__LYNXRPCPASS__/${rrpcpassword}/g" /root/LynxExplorer/settings.json

	# start IquidusExplorer process using pm2
	pm2 stop IquidusExplorer
	pm2 delete IquidusExplorer
	pm2 start npm --name IquidusExplorer -- start
	pm2 save
	pm2 startup ubuntu

	# Yeah, we are probably putting to many comments in this script, but I hope it proves
	# helpful to someone when they are having fun but don't know what a part of it does.

	print_success "Iquidus Explorer was installed"
}

install_blockcrawler () {
	
	apt-get install nginx php-fpm php-curl -y &> /dev/null

	print_success "Nginx was installed."
	print_success "PHP was installed."

	# Each OS has a unique sock file path.

	if [ "$version_id" = "9" -o "$version_id" = "8" ]; then

		rm -rf /etc/nginx/sites-available/default

		echo "
		server {
			listen 80 default_server;
			listen [::]:80 default_server;
			root /var/www/html/Blockcrawler;
			index index.php;
			server_name _;
			location / { try_files \$uri \$uri/ =404; }
			location ~ \.php$ {
				include snippets/fastcgi-php.conf;
				fastcgi_pass unix:/run/php/php7.0-fpm.sock;
			}
		}
		" > /etc/nginx/sites-available/default

		sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php/7.0/fpm/php.ini

	else

		rm -rf /etc/nginx/sites-available/default

		echo "
		server {
			listen 80 default_server;
			listen [::]:80 default_server;
			root /var/www/html/Blockcrawler;
			index index.php;
			server_name _;
			location / { try_files \$uri \$uri/ =404; }
			location ~ \.php$ {
				include snippets/fastcgi-php.conf;
				fastcgi_pass unix:/run/php/php7.2-fpm.sock;
			}
		}
		" > /etc/nginx/sites-available/default

		sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php/7.2/fpm/php.ini

	fi

	print_success "Nginx is configured."

	cd /var/www/html/ && wget http://cdn.getlynx.io/BlockCrawler.tar.gz
	tar -xvf BlockCrawler.tar.gz
	chmod 755 -R /var/www/html/Blockcrawler/
	chown www-data:www-data -R /var/www/html/Blockcrawler/
	
	sed -i -e 's/'"8332"'/'"$rpcport"'/g' /var/www/html/Blockcrawler/bc_daemon.php
	sed -i -e 's/'"username"'/'"$rrpcuser"'/g' /var/www/html/Blockcrawler/bc_daemon.php
	sed -i -e 's/'"password"'/'"$rrpcpassword"'/g' /var/www/html/Blockcrawler/bc_daemon.php

	systemctl restart nginx && systemctl enable nginx && systemctl restart php7.0-fpm

	iptables -I INPUT 3 -p tcp --dport 80 -j ACCEPT
	print_success "Block Crawler is installed."

}

# The MiniUPnP project offers software which supports the UPnP Internet Gateway Device (IGD)
# specifications. You can read more about it here --> http://miniupnp.free.fr
# We use this code because most folks don't know how to configure their home cable modem or wifi
# router to allow outside access to the Lynx node. While this Lynx node can talk to others, the 
# others on the network can't always talk to this device, especially if it's behind a router at 
# home. Currently, this library is only installed if the device is a Raspberry Pi.

install_miniupnpc () {

	if [ "$version_id" = "9" -o "$version_id" = "8" ]; then

		apt-get install libminiupnpc-dev -y	&> /dev/null
		print_success "Miniupnpc was installed."

	fi

}

install_lynx () {

	apt-get install git-core build-essential autoconf libtool libssl-dev libboost-all-dev libminiupnpc-dev libevent-dev libncurses5-dev pkg-config -y &> /dev/null

	rrpcuser="$(shuf -i 1000000000-3999999999 -n 1)$(shuf -i 1000000000-3999999999 -n 1)$(shuf -i 1000000000-3999999999 -n 1)"
	print_warning "The lynxd RPC user account is '$rrpcuser'."
	rrpcpassword="$(shuf -i 1000000000-3999999999 -n 1)$(shuf -i 1000000000-3999999999 -n 1)$(shuf -i 1000000000-3999999999 -n 1)"
	print_warning "The lynxd RPC user account is '$rrpcpassword'."

	print_success "Pulling the latest source of Lynx."

	# It isn't a bad idea to assume bad things might have happened before this build. Regardless
	# of the directory existing or not, delete it and start over again. It's just safer!

	rm -rf /root/lynx/

	# Pull down the latest stable production version of Lynx from the repo and drop it into the 
	# the preferred directory structure.

	git clone -b $lynxbranch https://github.com/doh9Xiet7weesh9va9th/lynx.git /root/lynx/

	# Since we are installing the wallet with this build, we need the Berkeley DB source. This 
	# database allows the client to store the keys needed by the wallet. Normally, we keep the 
	# build lightweight and don't install this dependency, but this extra package is needed for 
	# this case. Let's jump to the directory that was just created when we downloaded Lynx from
	# the repository and install the package there, to keep things nicely organized.

	print_success "Pulling the latest source of Berkeley DB."

	# We will need this db4 directory soon so let's delete and create it.

	rm -rf /root/lynx/db4
	mkdir -p /root/lynx/db4

	# We need a very specific version of the Berkeley DB for the wallet to function properly.

	cd /root/lynx/ && wget http://download.oracle.com/berkeley-db/db-4.8.30.NC.tar.gz

	# Now that we have the tarbar file, lets unpack it and jump to a sub directory within it.

	tar -xzvf db-4.8.30.NC.tar.gz && cd db-4.8.30.NC/build_unix/

	# Configure and run the make file to compile the Berkeley DB source.

	../dist/configure --enable-cxx --disable-shared --with-pic --prefix=/root/lynx/db4 && make install

	# Now that the Berkeley DB is installed, let's jump to the lynx directory and finish the 
	# configure statement WITH the Berkeley DB parameters included.
	
	cd /root/lynx/ && ./autogen.sh

	./configure LDFLAGS="-L/root/lynx/db4/lib/" CPPFLAGS="-I/root/lynx/db4/include/ -O2" --enable-cxx --without-gui --disable-shared --with-miniupnpc --enable-upnp-default --disable-tests && make

	print_success "The latest state of Lynx is being compiled, with the wallet enabled."

	# in the past, we used a bootstrap file to get the full blockchain history to load faster. This
	# was very helpful but it did bring up a security concern. If the bootstrap file had been
	# tampered with (even though it was created by Lynx dev team) it might prove a security risk.
	# So now that the seed nodes run faster and new node discovery is much more efficient, we are
	# phasing out the use of the bootstrap file.

	# Below we are creating the default lynx.conf file. This file is created with the dynamically
	# created RPC credentials and it sets up the networking with settings that testing has found to
	# work well in the LynxCI build. Of course, you can edit it further if you like, but this
	# default file is the recommended start point.

	cd ~/ && rm -rf .lynx && mkdir .lynx

	echo "
	listen=1
	daemon=1
	rpcuser=$rrpcuser
	rpcpassword=$rrpcpassword
	rpcport=$rpcport
	port=$port
	rpcbind=127.0.0.1
	rpcbind=::1
	rpcallowip=0.0.0.0/24
	rpcallowip=::/0
	listenonion=0
	upnp=1
	disablewallet=1
	txindex=1
	$lynxconfig

	" > /root/.lynx/lynx.conf

	chown -R root:root /root/.lynx/*

}

install_cpuminer () {

	apt-get install automake autoconf pkg-config libcurl4-openssl-dev libjansson-dev libssl-dev libgmp-dev make g++ -y &> /dev/null

	rm -rf /root/cpuminer
	git clone https://github.com/tpruvot/cpuminer-multi.git /root/cpuminer
	print_success "Mining package was downloaded."
	cd /root/cpuminer
	./autogen.sh

	if [ "$isPi" = "true" ]; then
		./configure --disable-assembly CFLAGS="-Ofast -march=native" --with-crypto --with-curl
	else 
		./configure CFLAGS="-march=native" --with-crypto --with-curl
	fi

	make

	print_success "CPUminer Multi was installed."

}

install_mongo () {

	apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv EA312927

	if [ "$version_id" = "9" -o "$version_id" = "8" ]; then

		echo "deb http://repo.mongodb.org/apt/debian jessie/mongodb-org/3.2 main" | sudo tee /etc/apt/sources.list.d/mongodb-org-3.2.list

	else

		# This else statement should evaluate if the installer is running anything other then Debian
		# 8 or Debian 9.

		echo "deb http://repo.mongodb.org/apt/ubuntu xenial/mongodb-org/3.2 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-3.2.list

	fi

	apt-get update -y &> /dev/null
	apt-get install -y mongodb-org &> /dev/null

	# Now that Mongo is installed. Let's be sure to start the service.

	systemctl start mongod
	systemctl enable mongod 

	# Because it can take a second or two for Mongo to start, let's let it breath for 5 seconds
	# so we don't try to operate on the service that isn't started yet.

	sleep 5

	account="{ user: 'x${rrpcuser}', pwd: 'x${rrpcpassword}', roles: [ 'readWrite' ] }" 

	mongo lynx --eval "db.createUser( ${account} )"

    print_success "MongoDB was installed."

}

set_firewall () {

	# To make sure we don't create any problems, let's truly make sure the firewall instructions
	# we are about to create haven't already been created. So we delete the file we are going to
	# create in the next step. This is just a step to insure stability and reduce risk in the 
	# execution of this build script.

	rm -rf /root/firewall.sh

	echo "

	#!/bin/bash

	IsSSH=Y

	# Let's flush any pre existing iptables rules that might exist and start with a clean slate.

	/sbin/iptables -F

	# We should always allow loopback traffic.

	/sbin/iptables -I INPUT 1 -i lo -j ACCEPT

	# This line of the script tells iptables that if we are already authenticated, then to ACCEPT
	# further traffic from that IP address. No need to recheck every packet if we are sure they
	# aren't a bad guy.

	/sbin/iptables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

	# The following 2 line are a very simple iptables access throttle technique. We assume anyone
	# who visits the local website on port 80 will behave, but if they are accessing the site too
	# often, then they might be a bad guy or a bot. So, these rules enforce that any IP address
	# that accesses the site in a 60 second period can not get more then 15 clicks completed. If the
	# bad guy submits a 16th page view in a 60 second period, the request is simply dropped and
	# and ignored. Its not super advanced but its one extra layer of security to keep this device 
	# stable and secure.

	/sbin/iptables -A INPUT -p tcp --dport 80 -m state --state NEW -m recent --set
	/sbin/iptables -A INPUT -p tcp --dport 80 -m state --state NEW -m recent --update --seconds 60 --hitcount 40 -j DROP

	# If the script has IsSSH set to Y, then let's open up port 22 for any IP address. But if
	# the script has IsSSH set to N, let's only open up port 22 for local LAN access. This means
	# you have to be physically connected (or via Wifi) to SSH to this computer. It isn't perfectly
	# secure, but it removes the possibility for an SSH attack from a public IP address. If you
	# wanted to completely remove the possibility of an SSH attack and will only ever work on this
	# computer with your own physically attached KVM (keyboard, video & mouse), then you can comment
	# the following 6 lines. Be careful, if you don't understand what you are doing here, you might
	# lock yourself from being able to access this computer. If so, just go through the build
	# process again and start over.

	if [ \"\$IsSSH\" = \"Y\" ]; then
		/sbin/iptables -A INPUT -p tcp --dport 22 -j ACCEPT
	else
		/sbin/iptables -A INPUT -p tcp -s 10.0.0.0/8 --dport 22 -j ACCEPT
		/sbin/iptables -A INPUT -p tcp -s 192.168.0.0/16 --dport 22 -j ACCEPT
	fi

	# Becuase the Block Explorer or Block Crawler are available via port 80 (standard website port)
	# we must open up port 80 for that traffic.

	/sbin/iptables -A INPUT -p tcp --dport 80 -j ACCEPT

	# This Lynx node listens for other Lynx nodes on port $port, so we need to open that port. The
	# whole Lynx network listens on that port so we always want to make sure this port is available.

	/sbin/iptables -A INPUT -p tcp --dport $port -j ACCEPT

	# By default, the RPC port 9223 is opened to the public. This is so the node can both listen 
	# for and discover other nodes. It is preferred to have a node that is not just a leecher but
	# also a seeder.

	/sbin/iptables -A INPUT -p tcp --dport $rpcport -j ACCEPT

	# We add this last line to drop any other traffic that comes to this computer that doesn't
	# comply with the earlier rules. If previous iptables rules don't match, then drop'em!

	/sbin/iptables -A INPUT -j DROP

	#
	# Metus est Plenus Tyrannis
	#" > /root/firewall.sh

	print_success "Firewall rules are set in /root/firewall.sh"

	chmod 700 /root/firewall.sh

}

set_miner () {

	rm -rf /root/miner.sh

	echo "
	#!/bin/bash

	# This valus is set during the initial build of this node by the LynxCI installer. You can
	# override it by changing the value. Acceptable options are Y and N. If you set the value to
	# N, this node will not mine blocks, but it will still confirm and relay transactions.

	IsMiner=Y

	# The objective of this script is to start the local miner and have it solo mine against the
	# local Lynx processes. So the first think we should do is assume a mining process is already
	# running and kill it.

	pkill -f cpuminer

	# Let's wait 2 seconds and give the task a moment to finish.

	sleep 2

	# If the flag to mine is set to Y, then lets do some mining, otherwise skip this whole
	# conditional. Seems kind of obvious, but some of us are still learning.

	if [ \"\$IsMiner\" = \"Y\" ]; then

		# Mining isnt very helpful if the process that run's Lynx isn't actually running. Why bother
		# running all this logic if Lynx isn't ready? Unfortunaately, this isnt the only check we need
		# to do. Just because Lynx might be running, it might not be in sync yet, and running the miner
		# doesnt make sense yet either. So, lets check if Lynxd is running and if it is, then we check
		# to see if the blockheight of the local node is _close_ to the known network block height. If
		# so, then we let the miner turn on.

		if pgrep -x \"lynxd\" > /dev/null; then

			# Only if the miner isn't running. We do this to ensure we don't accidently have two
			# miner processes running at the same time.

			if ! pgrep -x \"cpuminer\" > /dev/null; then

				# The Lynx network has a family of seed nodes that are publicly available. By querying
				# this single URL, the request will be randomly redirected to an active seed node. If
				# a seed node is down for whatever reason, the next query will probably select a
				# different seed node since no session management is used.

				remote=\$(curl -sL $explorer)

				# Since we know that Lynx is running, we can query our local instance for the current
				# block height.

				local=\$(/root/lynx/src/lynx-cli getblockcount)
				local=\$(expr \$local + 60)

				if [ \"\$local\" -ge \"\$remote\" ]; then

					# Just to make sure, lets purge any spaces of newlines in the file, so we don't
					# accidently pick one.

					chmod 644 /root/LynxNodeBuilder/miner-addresses.txt

					# Randomly select an address from the addresse file. You are welcome to change 
					# any value in that list.

					random_address=\"\$(shuf -n 1 /root/LynxNodeBuilder/$addresses)\"

					# With the randomly selected reward address, lets start solo mining.

					/root/cpuminer/cpuminer -o http://127.0.0.1:$rpcport -u $rrpcuser -p $rrpcpassword --no-longpoll --no-getwork --no-stratum --coinbase-addr=\"\$random_address\" -t 1 -R 15 -B -S
	
				fi

			fi

		fi

	fi

	# If the process that throttles the miner is already running, then kill it. Just to be sure.

	pkill -f cpulimit

	# Let's wait 2 seconds and give the task a moment to finish.

	sleep 2

	# If the miner flag is set to Y, the execute this conditional group.

	if [ \"\$IsMiner\" = \"Y\" ]; then

		# Only set the limiter if the miner is actually running. No need to start the process if not
		# needed.

		if pgrep -x \"cpuminer\" > /dev/null; then

			# Only if the cpulimit process isn't already running, then start it.

			if ! pgrep -x \"cpulimit\" > /dev/null; then

				# Let's set the amount of CPU that the process cpuminer can use to 5%.

				cpulimit -e cpuminer -l 5 -b
			fi

		fi

	fi

	#
	# Metus est Plenus Tyrannis
	#" > /root/miner.sh

	chmod 700 /root/miner.sh
	chown root:root /root/miner.sh

}

# This function is still under development.

install_ssl () {

	#https://calomel.org/lets_encrypt_client.html
	print_success "SSL creation scripts are still in process."

}

# This function is still under development.

install_tor () {

	apt install tor
	systemctl enable tor
	systemctl start tor

	echo "
	ControlPort 9051
	CookieAuthentication 1
	CookieAuthFileGroupReadable 1
	" >> /etc/tor/torrc

	usermod -a -G debian-tor root

}

secure_iptables () {

	iptables -F
	iptables -I INPUT 1 -i lo -j ACCEPT
	iptables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -A INPUT -p tcp --dport 22 -j ACCEPT
	iptables -A INPUT -j DROP

}

config_fail2ban () {
	#
	# Configure fail2ban defaults function
	#

	#
	# The default ban time for abusers on port 22 (SSH) is 10 minutes. Lets make this a full 24 hours
	# that we will ban the IP address of the attacker. This is the tuning of the fail2ban jail that
	# was documented earlier in this file. The number 86400 is the number of seconds in a 24 hour term.
	# Set the bantime for lynxd on port 22566/44566 banned regex matches to 24 hours as well.

	echo "

	[sshd]
	enabled = true
	bantime = 86400


	[lynxd]
	enabled = false
	bantime = 86400

	" > /etc/fail2ban/jail.d/defaults-debian.conf

	#
	#
	# Configure the fail2ban jail for lynxd and set the frequency to 20 min and 3 polls.

	echo "

	#
	# SSH
	#

	[sshd]
	port		= ssh
	logpath		= %(sshd_log)s

	#
	# LYNX
	#

	[lynxd]
	port		= $port
	logpath		= /root/.lynx/debug.log
	findtime	= 1200
	maxretry	= 3

	" > /etc/fail2ban/jail.local

	# Define the regex pattern for lynxd failed connections

	echo "

	#
	# Fail2Ban lynxd regex filter for at attempted exploit or inappropriate connection
	#
	# The regex matches banned and dropped connections
	# Processes the following logfile /root/.lynx/debug.log
	#

	[INCLUDES]

	# Read common prefixes. If any customizations available -- read them from
	# common.local
	before = common.conf

	[Definition]

	#_daemon = lynxd

	failregex = ^.* connection from <HOST>.*dropped \(banned\)$

	ignoreregex =

	# Author: The Lynx Core Development Team

	" > /etc/fail2ban/filter.d/lynxd.conf

	#
	#
	# With the extra jails added for monitoring lynxd, we need to touch the debug.log file for fail2ban to start without error.
	mkdir /root/.lynx/
	chmod 755 /root/.lynx/
	touch /root/.lynx/debug.log

	service fail2ban start

}

setup_crontabs () {
	
	# In the event that any other crontabs exist, let's purge them all.

	crontab -r

	# The following 3 lines set up respective crontabs to run every 15 minutes. These send a polling
	# signal to the listed URL's. The ONLY data we collect is the MAC address, public and private
	# IP address and the latest known Lynx block heigh number. This allows development to more 
	# accurately measure network usage and allows the pricing calculator and mapping code used by
	# Lynx to be more accurate. If you want to turn off particiaption in the polling service, all
	# you have to do is remove the following 3 crontabs.

	crontab -l | { cat; echo "*/15 * * * *		/root/LynxNodeBuilder/poll.sh http://seed00.getlynx.io:8080"; } | crontab -
	crontab -l | { cat; echo "*/15 * * * *		/root/LynxNodeBuilder/poll.sh http://seed01.getlynx.io:8080"; } | crontab -
	crontab -l | { cat; echo "*/15 * * * *		/root/LynxNodeBuilder/poll.sh http://seed02.getlynx.io:8080"; } | crontab -

	# Every 15 minutes we reset the firewall to it's default state. Additionally we reset the miner.
	# The lynx daemon needs to be checked too, so we restart it if it crashes (which has been been
	# known to happen on low RAM devices during blockchain indexing.)

	crontab -l | { cat; echo "*/15 * * * *		/root/firewall.sh"; } | crontab -
	crontab -l | { cat; echo "*/15 * * * *		/root/lynx/src/lynxd"; } | crontab -
	crontab -l | { cat; echo "*/15 * * * *		/root/miner.sh"; } | crontab -

	# We found that after a few weeks, the debug log would grow rather large. It's not really needed
	# after a certain size, so let's truncate that log down to a reasonable size every 2 days.

	crontab -l | { cat; echo "0 0 */2 * *		truncate -s 1KB /root/.lynx/debug.log"; } | crontab -

	# Evey 15 days we will reboot the device. This is for a few reasons. Since the device is often
	# not actively managed by it's owner, we can't assume it is always running perfectly so an
	# occasional reboot won't cause harm. This crontab means to reboot EVERY 15 days, NOT on the
	# 15th day of the month. An important distinction.

	crontab -l | { cat; echo "0 0 */15 * *		/sbin/shutdown -r now"; } | crontab -

	# This conditional determines if the local machine has more then 1024 MB of RAM available. If it
	# does, then we assume the device can handle a little more work, so we run processes that
	# consume more RAM. If it does not evaluate positive, then we run the lightweight processes.
	# For refernence, 1,024,000 KB = 1024 MB

	if [[ "$(awk '/MemTotal/' /proc/meminfo | sed 's/[^0-9]*//g')" -gt "512000" ]]; then

		crontab -l | { cat; echo "*/2 * * * *		cd /root/LynxExplorer && scripts/check_server_status.sh"; } | crontab -
		crontab -l | { cat; echo "*/3 * * * *		cd /root/LynxExplorer && /usr/bin/nodejs scripts/sync.js index update >> /tmp/explorer.sync 2>&1"; } | crontab -
		crontab -l | { cat; echo "*/4 * * * *		cd /root/LynxExplorer && /usr/bin/nodejs scripts/sync.js market > /dev/null 2>&1"; } | crontab -
		crontab -l | { cat; echo "*/10 * * * *		cd /root/LynxExplorer && /usr/bin/nodejs scripts/peers.js > /dev/null 2>&1"; } | crontab -

	fi

}

restart () {

	# We now write this empty file to the /boot dir. This file will persist after reboot so if
	# this script were to run again, it would abort because it would know it already ran sometime
	# in the past. This is another way to prevent a loop if something bad happens during the install
	# process. At least it will fail and the machine won't be looping a reboot/install over and 
	# over. This helps if we have ot debug a problem in the future.

	touch /boot/lynxci

	print_success "This Lynx node is built. A reboot and autostart will occur 30 seconds."

	sleep 5

	print_success "Please change the default password for the '$ssuser' user after reboot!"

	sleep 5

	print_success "After boot, it will take 5 minutes for all services to start. Be patient."

	sleep 5

	# Now we truly reboot the OS.

	reboot

}

# First thing, we check to see if this script already ran in the past. If the file "/boot/lynxci"
# exists, we know it did. So we assume all went well and then the script is done running. 

if [ -f /boot/lynxci ]; then

	print_error "Previous LynxCI detected. Install aborted."

	# Since the file "/boot/lynxci", was NOT found, we know this is the first time this script has run
	# so we let it do it's thing.

else

	print_error "Starting installation of LynxCI."
	print_error ""
	print_error "This will be a cpu and memory intensive process that could last hours"
	print_error "...depending on your hardware."

	# Let's print to the screen some info about what packages will be installed.

	print_error ""
	if [[ "$(awk '/MemTotal/' /proc/meminfo | sed 's/[^0-9]*//g')" -gt "512000" ]]; then
		print_error "More then 512 MB of RAM is detected. The robust Block Explorer will be installed."
	else
		print_error "Less then 512 MB of RAM is detected. The modest Block Crawler will be installed."
	fi
	print_error ""

	detect_os
	install_extras
	detect_vps
	set_network
	update_os
	expand_swap
	reduce_gpu_mem
	disable_bluetooth
	set_wifi
	set_accounts
	install_portcheck
	install_miniupnpc
	install_lynx
	
	# This conditional determines if the local machine has more then 1024 MB of RAM available. If it
	# does, then we assume the device can handle a little more more work, sp we run processes that
	# consume more RAM. If it does not evaluate positive, then we run the lightweight processes.
	# For refernence, 1,024,000 KB = 1024 MB

	if [[ "$(awk '/MemTotal/' /proc/meminfo | sed 's/[^0-9]*//g')" -gt "512000" ]]; then
		install_mongo
		install_iquidusExplorer
	else
		install_blockcrawler
	fi

	install_cpuminer
	set_firewall
	set_miner
	secure_iptables
	config_fail2ban
	setup_crontabs
	restart

fi