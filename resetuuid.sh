#/usr/bin/env bash

# WARNING: This script is provided "as is" without warranty of any kind, \
# express or implied, including, but not limited to, \
# the implied warranties of fitness for a particular purpose, and non-infringement.
# The goal of this script is resetting the various UUIDs of "Citrix Hypervisor 8.2 CU1" VM when you cloning it in an "nested" laboratory.
# DON'T run this script in production or non-fresh deployed hypervisor or you have to take your own risk of data lose.

#variables setting here:
log=/resetuuid.log
rclocal=/etc/rc.d/rc.local
timeout=300
step=5

crt() {
echo "deleting xapi-ssl certificate" >> $log
rm -f /etc/xensource/xapi-ssl.pem
echo "generating xapi-ssl certificate" >> $log
systemctl restart gencert.service
}

savesrinfo() {
	local timer=$timeout
	while [ $timer -gt 0 ]; do
		if xe sr-list > /dev/null 2>&1; then
			echo "entering getting srinfo" >> $log
			xe pool-param-clear param-name=default-SR uuid=$(xe pool-list --minimal)
			local i=0
			for ID in $(xe sr-list --minimal | sed s/,/\ /g); do
				SRUUIDS[$i]="$ID"
				PBDUIDS[$i]="$(xe pbd-list sr-uuid=$ID --minimal)"
				SRNAMES[$i]="$(xe sr-list uuid=$ID params=name-label --minimal)";
				SRTYPES[$i]="$(xe sr-list uuid=$ID params=type --minimal)";
				CNTYPES[$i]="$(xe sr-list uuid=$ID params=content-type --minimal)";
				PBDCFGS[$i]="$(xe pbd-list sr-uuid=$ID params=device-config --minimal | sed s/\:\ /=/g)";
				((i++));
			done;
			echo "end getting srinfo" >> $log
			break
		else
			echo "savesrinfo: cannot connect to xapi, timeout in $timer second(s)" >> $log
		fi
		sleep $step
		((timer-=$step))
	if  [ $timer -eq 0 ]; then
		echo "createsr: timeout reaches $timer before connected to xapi, check xapi status"
		exit 1;
	fi
	done
}

deletesr() {
	local i=0
	while [ $i -lt ${#SRNAMES[*]} ]; do
		echo "unplug pbd for ${SRNAMES[$i]}" >> $log
		xe pbd-unplug uuid=${PBDUIDS[$i]};
		echo "${SRNAMES[$i]} unplugged" >> $log
		echo "destroying pbd for ${SRNAMES[$i]}" >> $log
		xe pbd-destroy uuid=${PBDUIDS[$i]};
		echo "${SRNAMES[$i]} destroyed" >> $log
		echo "forgetting SR: ${SRNAMES[$i]}" >> $log
		xe sr-forget uuid=${SRUUIDS[$i]};
		echo "${SRNAMES[$i]} forgotten" >> $log
		((i++))
	done
}

createsr() {
	local timer=$timeout
	while [ $timer -gt 0 ]; do
		if xe sr-list > /dev/null 2>&1; then
			sleep $step
			if [ ${#SRNAMES[*]} -eq 0 ]; then
				echo "srinfo arraies are empty, exiting..." >> $log
				exit 2
			else
				local i=0
				while [ $i -lt ${#SRNAMES[*]} ]; do
					echo "recreating SR: ${SRNAMES[$i]}" >> $log
					xe sr-create shared=false host-uuid=$(xe host-list --minimal) name-label="${SRNAMES[$i]}" type=${SRTYPES[$i]} content-type=${CNTYPES[$i]} device-config:${PBDCFGS[$i]} > /dev/null;	
					echo "SR ${SRNAMES[$i]} created" >> $log
					((i++))
				done
			fi
		break
		else
			echo "createsr: cannot connect to xapi, timeout in $timer second(s)" >> $log
		fi
		sleep $step
		((timer-=$step))
	if  [ $timer -eq 0 ]; then
		echo "createsr: timeout reaches $timer before connected to xapi, check xapi status"
		exit 1;
	fi
	done
}

dom0() {
	echo "stopping xapi toolstack" >> $log
	systemctl stop stunnel@xapi
	for svc in perfmon xapi v6d xenopsd xenopsd-xc xenopsd-xenlight xenopsd-simulator xenopsd-libvirt xcp-rrdd-iostat xcp-rrdd-squeezed xcp-rrdd-xenpm xcp-rrdd-gpumon xcp-rrdd xcp-networkd squeezed forkexecd mpathalert xapi-storage-script xapi-clusterd varstored-guard message-switch; do
		systemctl stop $svc
	done
	echo "generating new host ID and dom0 ID" >> $log
	hostID=$(/usr/bin/uuidgen)
	dom0ID=$(/usr/bin/uuidgen)
	sed -i "/INSTALLATION_UUID=*/c\INSTALLATION_UUID=\'$hostID\'" /etc/xensource-inventory
	sed -i "/CONTROL_DOMAIN_UUID=*/c\CONTROL_DOMAIN_UUID=\'$dom0ID\'" /etc/xensource-inventory
	echo "deleting current xapi database" >> $log
	rm -f /var/xapi/state.db
	echo "starting xapi toolstack and regenerate new xapi database" >> $log
	for svc in perfmon xapi v6d xenopsd xenopsd-xc xenopsd-xenlight xenopsd-simulator xenopsd-libvirt xcp-rrdd-iostat xcp-rrdd-squeezed xcp-rrdd-xenpm xcp-rrdd-gpumon xcp-rrdd xcp-networkd squeezed forkexecd mpathalert xapi-storage-script xapi-clusterd varstored-guard message-switch; do
		systemctl is-enabled $svc >/dev/null 2>&1
		if [ $? -eq 0 ]; then
			systemctl start $svc
		fi
	done
}

ovs() {
	echo "stopping OVS services" >> $log
	systemctl stop openvswitch openvswitch-xapi-sync 
	echo "deleting OVS database" >> $log
	rm -f /etc/openvswitch/conf.db*
	echo "starting OVS services" >> $log
	systemctl start openvswitch openvswitch-xapi-sync 
	echo "initializing new OVS database" >> $log
	echo yes | /opt/xensource/bin/xe-reset-networking --device=eth0 --mode=dhcp
}

myself=$(readlink -ms $0)

case $1 in
reset)
	crt
	savesrinfo
	deletesr
	dom0
	createsr
	if [ ! -z "$(grep $myself $rclocal)" ]; then
		echo "invoking $myself with parameter: uninstall" >> $log
		$myself uninstall
	fi
	ovs
	exit 0
;;

install)
	echo "assign executable privilege to necessary files" >> $log
	chmod +x $rclocal
	chmod +x $myself
	echo "updating rc.local" >> $log
	cat <<EoF >> $rclocal
#!/usr/bin/env bash
case \$1 in
start)
	$myself reset
;;
*)
;;
esac
EoF
	echo "updating rc.local done" >> $log
;;

uninstall)
	echo "removing executable privilege to files while installing $0" >> $log
	chmod -x $rclocal
	echo "removing lines we added into rc.local" >> $log
	awk "/$(basename $0)/"'{for(x=NR-3;x<=NR+4;x++)d[x];}{a[NR]=$0}END{for(i=1;i<=NR;i++)if(!(i in d))print a[i]}' $rclocal > /tmp/rc.new && cat /tmp/rc.new > $rclocal && rm -f /tmp/rc.new
#	echo "deleting $myself" >> $log
#	rm -f $myself
;;

*)
	echo "Usage will be: $0 [reset | install | uninstall]"
;;
esac
