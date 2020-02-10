#!/bin/sh
# Custom implementation for power management by addon board x735v1
# uses *gpio-watch* from https://github.com/larsks/gpio-watch.git
# _Requires_ additional connection of the power button to pin 16

if ! command -v git > /dev/null; then
	sudo apt install -y git
fi
if ! command -v make > /dev/null; then
	sudo apt install -y build-essential
fi

poweroff_path="/usr/local/bin/x735_poweroff.sh"

get_gpio_watch()
{
	local builddir; builddir=$(mktemp -d)
	cd "$builddir" && \
	git clone https://github.com/larsks/gpio-watch.git && \
	cd gpio-watch && \
	make && \
	sudo make install && \
	sudo mkdir -p /etc/gpio-scripts && \
	rm -Rf "$builddir"
}

install_startup_script()
{
	if [ -z "$1" ]; then
		echo "No startup script path provided, breaking up!"
		exit 1
	fi
	local targetfn; targetfn="$1"
	local tempfn; tempfn="$(mktemp)"
	cat > "$tempfn" << EOF
#!/bin/sh

PINBTN=16
echo "\$PINBTN" > /sys/class/gpio/export
echo in > /sys/class/gpio/gpio\$PINBTN/direction
# create shutdown script
scriptfn="/etc/gpio-scripts/\$PINBTN"
# shutdown calls x735 poweroff script via systemd runonce service
(echo "#!/bin/sh";
 echo "sudo /sbin/shutdown -h now";) > "\$scriptfn" && \
chmod 755 "\$scriptfn"

PINBOOT=17
echo "\$PINBOOT" > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio\$PINBOOT/direction
echo 1 > /sys/class/gpio/gpio\$PINBOOT/value

#gpio-watch -l /var/log/gpio-watch_\$PINBTN.log \$PINBTN:switch &
# on button press, custom pin goes from 1->0->1 (on pushing down)
gpio-watch -l /var/log/gpio-watch_\$PINBTN.log \$PINBTN:falling &

EOF
	if [ ! -f "$tempfn" ]; then
		echo "Could not create x735 startup script!"
		return
	fi
	chmod 755 "$tempfn" && \
	sudo mv "$tempfn" "$targetfn" && \
	sudo chown root.root "$targetfn" && \
	sudo sed -i -e "\#^$targetfn# d" /etc/rc.local && \
   	sudo sed -i -e "$ i $targetfn" /etc/rc.local
}

install_poweroff_script()
{
	if [ -z "$1" ]; then
		echo "No power off script path provided, breaking up!"
		exit 1
	fi
	local targetfn; targetfn="$1"
	local tempfn; tempfn="$(mktemp)"
	cat > "$tempfn" << EOF
#!/bin/sh
# largely identical to https://github.com/geekworm-com/x730-script

BUTTON=18
echo "\$BUTTON" > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio\$BUTTON/direction
echo 1 > /sys/class/gpio/gpio\$BUTTON/value

TIMEOUT=\${1:-4}
TIMEOUT=3

if ! echo "\$TIMEOUT" | egrep -q '^[0-9\\.]+$'; then
    echo "ERROR: Sleep timeout '\$TIMEOUT' not a number!" >&2
    exit 1
fi

echo "X730 Shutting down in \$TIMEOUT seconds ..."
/bin/sleep \$TIMEOUT

# restore GPIO 18
echo 0 > /sys/class/gpio/gpio\$BUTTON/value

EOF
	if [ ! -f "$tempfn" ]; then
		echo "Could not create x735 poweroff script!"
		return
	fi
	chmod 755 "$tempfn" && \
	sudo mv "$tempfn" "$targetfn" && \
	sudo chown root.root "$targetfn"
}

install_systemd_service()
{
	if [ -z "$1" ]; then
		echo "No power off script path provided, breaking up!"
		exit 1
	fi
	local poweroff_path; poweroff_path="$1"
	local targetfn; targetfn=/etc/systemd/system/x735_before_shutdown.service
	local service_name; service_name="$(basename "$targetfn")"
	local tempfn; tempfn="$(mktemp)"
	cat > "$tempfn" << EOF
[Unit]
Description=Before Shutting Down
After=reboot.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true
ExecStop=$poweroff_path

[Install]
WantedBy=multi-user.target
EOF
	if [ ! -f "$tempfn" ]; then
		echo "Could not create x735 systemd service!"
		return
	fi
	chmod 644 "$tempfn" && \
	sudo mv "$tempfn" "$targetfn" && \
	sudo chown root.root "$targetfn" && \
	sudo systemctl daemon-reload && \
	sudo systemctl enable "$service_name" && \
	sudo systemctl start "$service_name"
}

get_gpio_watch
install_startup_script "/usr/local/bin/x735_onStartup.sh"
install_poweroff_script "$poweroff_path"
install_systemd_service "$poweroff_path"

# vim: set ts=4 sts=4 sw=4 tw=0:
