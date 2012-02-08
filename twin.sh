#!/bin/sh
#
# description: Manage twinned hosting
# This file belongs in /usr/local/sbin
#

# Note: To connect to the KVM monitor to issue commands interractively, use
# nc -U /media/archive/ic025/.ic025.monitor

# This script requires the following directories to be on the PATH
# So if called from crontab and init scripts, PATH must include them
# /bin:         file handling, basename, sleep, kill
# /usr/bin:     ssh rsync qemu-kvm socat shmysql shsql
# /usr/sbin:    lvcreate, lvremove
# /usr/local/sbin twin (in receive mode, the script calls itself to restart VMs)

#. /etc/init.d/functions
. /usr/local/etc/twin.conf

# The name of this script
SCRIPTNAME=`basename $0`

################################################################################
# Start & Stop

# Use the VM name to get the config file index
function twin_id() {
       local vmname=$1

       for (( i=0; i<$VMCOUNT; i++ ))
       do
               if [ ${VMNAME[i]} = $vmname ];
               then
                       return $i
               fi
       done

       echo "ERROR: The configuration does not contain a VM named $vmname" >&2
       exit 1
}

function isrunning() {
       local vmname=$1
       local pidfile=${WORK_DIR}/${vmname}/.${vmname}.pid

       if [ -r ${pidfile} ]; then
               # Use 'head' because we only want the first line
               # and kvm has been known to append a 2nd line, causing a syntax error in the following 'if' statement
               pid=`head -n1 ${pidfile} 2>/dev/null`
               if [ ! -z "${pid}" -a -d /proc/${pid} ]; then
                       return 0 #Success - running
               else
                       return 1 #Failure - not running
               fi
       else
               return 1 #Failure - not running
       fi
}

function start_twin() {
    local vmname=$1
    local test_mode=$2
	#local vmid=`twin_id $vmname`
	twin_id $vmname
	local vmid=$?

    if [ "${MEMORY[$vmid]}" ]; then
        memoryarg="-m ${MEMORY[$vmid]}"
    elif [ "$MEMORYDEFAULT" ]; then
        memoryarg="-m $MEMORYDEFAULT"
    else
        memoryarg=""
    fi

    if [ "${PROCESSORS[$vmid]}" ]; then
        processorarg="-smp ${PROCESSORS[$vmid]}"
    elif [ "$PROCESSORSDEFAULT" ]; then
        processorarg="-smp $PROCESSORSDEFAULT"
    else
        processorarg=""
    fi

    if $test_mode ; then
        local monitorfile=${WORK_DIR}/${vmname}-test/.${vmname}-test.monitor
        local pidfile=${WORK_DIR}/${vmname}-test/.${vmname}-test.pid
	#local mac_addr="02:00:0${VMSTATUS[${vmid}]}:01:${VMNUMBER[${vmid}]}:00"
	local mac_addr="02:00:0${VMSTATUS[${vmid}]}:01:${SERVERID}:00"

        echo "Starting ${vmname}-test"

	/usr/libexec/qemu-kvm -k en-gb $memoryarg $processorarg \
		-pidfile ${pidfile} \
		-monitor unix:${monitorfile},server,nowait \
		-usb -usbdevice tablet \
		-net nic,macaddr=${mac_addr} \
		-net tap,script=/etc/incharge/qemu-ifup \
		-vnc :9 \
		-hda ${WORK_DIR}/${vmname}/incoming/hda.raw \
		-hdd ${WORK_DIR}/${vmname}/incoming/twintest.raw &
    else
        local monitorfile=${WORK_DIR}/${vmname}/.${vmname}.monitor
        local pidfile=${WORK_DIR}/${vmname}/.${vmname}.pid
	#local mac_addr="02:00:0${VMSTATUS[${vmid}]}:00:${VMNUMBER[${vmid}]}:0${SLOT[${vmid}]}"
	local mac_addr="02:00:0${VMSTATUS[${vmid}]}:00:${SERVERID}:0${SLOT[${vmid}]}"

        echo "Starting VM ${vmname} at: `date`"
        if isrunning $vmname; then
            echo 'The VM is already running'
        else
            /usr/libexec/qemu-kvm -k en-gb $memoryarg $processorarg \
		-pidfile ${pidfile} \
		-monitor unix:${monitorfile},server,nowait \
		-usb -usbdevice tablet \
		-net nic,macaddr=${mac_addr} \
		-net tap,script=/etc/incharge/qemu-ifup \
		-vnc :${SLOT[$vmid]} \
		-hda /media/${vmname}/hda.raw \
		-hdb /media/archive/${vmname}/hdb.raw \
		-hdc /media/archive/${vmname}/hdc.raw &
        fi
    fi
}

function stop_twin() {
       local vmname=$1
       local monitorfile=${WORK_DIR}/${vmname}/.${vmname}.monitor
       local pidfile=${WORK_DIR}/${vmname}/.${vmname}.pid

       if isrunning $vmname; then
               echo "Stopping ${vmname} at: `date`"

               # Send nice powerdown command
               echo 'system_powerdown' | socat - UNIX-CONNECT:${monitorfile} >/dev/null
               for (( i = 0 ; i <= ${SHUTDOWN_TIMEOUT} ; i++ )); do
                       if isrunning $vmname; then
                               echo -n '.'
                               sleep 1
                       else
                               break;
                       fi
               done

               if isrunning $vmname; then
                       echo 'forcing...'
                       kill -TERM "${pid}"
                       sleep 2
               fi

               echo '.'

               if isrunning $vmname; then
                       echo 'problem stopping!'
                       exit 1
               fi

               rm ${monitorfile}
               rm ${pidfile}
               echo "Stopped ${vmname} at: `date`"
       else
               echo "${vmname} is already stopped"
       fi
}

################################################################################
# Send

# Connect to the database and lock it
# The resulting database handle is written to stdout
# so no status messages may be written to stdout
function database_lock() {
       local sqlhandle

       sqlhandle=`shmysql host=$3 port=$4 user=$1 password=$2`

       if [ $sqlhandle ]; then
               shsql $sqlhandle "begin"
               shsql $sqlhandle 'FLUSH TABLES WITH READ LOCK;'
       else
               echo 'Failed to connect to mysql' >&2
       fi

       echo $sqlhandle
}

# Unlock the database and close the connection
function database_unlock() {
       local sqlhandle=$1

       if [ $sqlhandle ]; then
               echo 'Unocking database'
               shsql $sqlhandle 'UNLOCK TABLES;'
               shsqlend $sqlhandle
       fi
}

# Create an LVM snapshot of the VM
function start_snapshot() {
       local vmname=$1

       echo 'Creating snapshot'
       mkdir ${MOUNTPOINT}/${vmname}-snapshot/
       lvcreate --size ${SNAPSHOTSIZE} --snapshot --name ${vmname}-snapshot ${LVMDEV}/${vmname}
       mount ${LVMDEV}/${vmname}-snapshot ${MOUNTPOINT}/${vmname}-snapshot
}

# Remove the LVM snapshot of the VM
function stop_snapshot() {
       local vmname=$1

       if [ -e "${MOUNTPOINT}/${vmname}-snapshot" ]
       then
               echo 'Removing snapshot'
               umount ${MOUNTPOINT}/${vmname}-snapshot/
               lvremove --force ${LVMDEV}/${vmname}-snapshot
               rmdir ${MOUNTPOINT}/${vmname}-snapshot/
       fi
}

# Use rsync to synchronise the virtual disk file
function synchronise() {
       local vmname=$1
       local diskname=$2

       # For testing, put a small test file in ${MOUNTPOINT}/${vmname}
       # and sync this file instead of the virtual disk
       # diskname=test.txt

       echo `date --rfc-2822` ": Synchronizing $vmname"

       # Delete the remote trigger file
       ssh -p $REMOTEPORT -l $REMOTEUSERNAME -i $REMOTEKEY ${REMOTEIP} "rm --force ${REMOTEDIR}/${vmname}/incoming/complete.txt"

       # Synchronise the virtual disk file
       rsync --inplace --ignore-times --bwlimit=${BWLIMIT} --verbose --stats --human-readable --rsh "ssh -p $REMOTEPORT -l $REMOTEUSERNAME -i $REMOTEKEY" ${MOUNTPOINT}/${vmname}-snapshot/${diskname} ${REMOTEIP}:${REMOTEDIR}/${vmname}/incoming/

       # Create the remote trigger file
       ssh -p $REMOTEPORT -l $REMOTEUSERNAME -i $REMOTEKEY ${REMOTEIP} "touch ${REMOTEDIR}/${vmname}/incoming/complete.txt"

       echo `date --rfc-2822` ": Synchronized $vmname"
}

send_twin() {
       local vmid=$1
       local vmname=${VMNAME[$vmid]}
       local sqlhandle=''

       echo "Start sending $vmname at" `date --rfc-2822`
       echo "Start sending $vmname at" `date --rfc-2822` >&2

       # Remove the snapshot if it is left over from a previous failed run
       stop_snapshot $vmname

       # Flush & lock the database on the guest server
       if [ "${DBUSERNAME[$vmid]}" ]; then
               # DB credentials are provided, so lock the database
               echo "Locking mysql database"
               sqlhandle=$(database_lock ${DBUSERNAME[$vmid]} ${DBPASSWORD[$vmid]} ${GUESTIP[$vmid]} ${DBPORT[$vmid]} )
       fi

       # Start the LVM snapshot
       start_snapshot $vmname

       # Unlock the database on the guest server
       if [ "${DBUSERNAME[$vmid]}" ]; then
               database_unlock $sqlhandle
       fi

       # Synchronise the virtual hard disk
       # The 2nd parameter is the filename of the virtual disk
       synchronise $vmname "hda.raw"

       # Stop the LVM snapshot
       stop_snapshot $vmname

       echo "End sending $vmname at" `date --rfc-2822`
       echo "End sending $vmname at" `date --rfc-2822` >&2
}

function send_twins() {
       for (( i=0; i<$VMCOUNT; i++ ))
       do
               if [ ${VMSTATUS[i]} = 0 ];
               then
                       send_twin $i
               fi
       done
}

function send_twin_by_name() {
       local vmname=$1

       # Convert VM name to id
       twin_id $vmname
       local vmid=$?

       send_twin $vmid
}

################################################################################
# Receive

function receive_twin() {
    local vmid=$1
    local vmname=${VMNAME[$vmid]}
    local testname="${vmname}-test"

    if [ -f ${WORK_DIR}/${vmname}/incoming/complete.txt ];
    then
        # There is a new file waiting
        echo "Start receiving $vmname at" `date --rfc-2822`
        echo "Start receiving $vmname at" `date --rfc-2822` >&2

	# Remove the flag file immediately
	# to prevent another 'twin receive' kicking in
        rm ${WORK_DIR}/${vmname}/incoming/complete.txt

        mkdir ${WORK_DIR}/${vmname}-test/
        mkdir /mnt/${vmname}-test/
	umount ${WORK_DIR}/${vmname}/incoming/twintest.raw 

        start_twin "$vmname" true

	sleep 5

        echo "Waiting for ${vmname}-test to get its act together"
        echo "Waiting for ${vmname}-test to get its act together" >&2
        for (( c=0; c<${TEST_TIMEOUT}; c++ ))
        do
            if isrunning "$testname"; then
                sleep 1
            else
		echo "${vmname}-test stopped running"
                break
            fi
        done

        if isrunning "$testname"; then
            stop_twin "${vmname}-test"  
            echo "Warning: ${vmname}-test had to be forcibly shut down"
            echo "Warning: ${vmname}-test had to be forcibly shut down" >&2
        fi

        # Check if the test ran successfully
        mount -o loop,offset=65536 ${WORK_DIR}/${vmname}/incoming/twintest.raw /mnt/${vmname}-test

        if [ ! -f /mnt/${vmname}-test/startup.txt ]; then
		echo "Error! Test has not responded so not replacing old backup"
		echo "Error! Test has not responded so not replacing old backup" >&2
		exit 1
        else
		rm /mnt/${vmname}-test/startup.txt
		stop_twin "$vmname"
		nice ionice -c3 cp --sparse=always ${WORK_DIR}/${vmname}/incoming/hda.raw ${MOUNTPOINT}/${vmname}/
		start_twin "$vmname" false

		echo "End receiving $vmname at" `date --rfc-2822`
		echo "End receiving $vmname at" `date --rfc-2822` >&2
        fi

        umount ${WORK_DIR}/${vmname}/incoming/twintest.raw 
    fi
}

function receive_twins() {
       for (( c=0; c<$VMCOUNT; c++ ))
       do
            if [ ${VMSTATUS[c]} = 1 ]; then
                       receive_twin $c
            fi
       done
}

function config()
{
       vi /usr/local/etc/twin.conf
}

function morelog ()
{
       less +G $LOGFILE
}

function moreerr ()
{
       less +G $ERRFILE
}

################################################################################
# Main

function twin_test() {
       local vmname=$1
       twin_id $vmname
       local vmid=$?
       echo "Have $vmid"
}

case "$1" in
       'test')
               twin_test "$2"
               ;;

       'start')
               if [ "$2" ]; then
                       start_twin "$2" false
               else
                       echo "Usage: $SCRIPTNAME start vmname"
               fi
               ;;

       'stop')
               if [ "$2" ]; then
                       stop_twin "$2"
               else
                       echo "Usage: $SCRIPTNAME stop vmname"
               fi
               ;;

       'send')
               if [ "$2" ]; then
                       # Send the named vm
                       send_twin_by_name "$2"
               else
                       # Send all vms
                       send_twins
               fi
               ;;

       'receive')
               if [ "$2" ]; then
                  receive_twin "$2"
               else
                  # receive all vms
                  receive_twins
               fi
               ;;

       'isrunning')
		if isrunning "$2"; then
			echo "running"
		fi
		;;

       'config')
               config
               ;;

       'morelog')
               morelog
               ;;

       'moreerr')
               moreerr
               ;;

       *)
               echo "Usage: $SCRIPTNAME {start|stop|send|receive|config|morelog|moreerr}"
               exit 1
               ;;
esac


exit 0
