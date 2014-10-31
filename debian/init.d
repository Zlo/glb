#!/bin/sh

### BEGIN INIT INFO
# Provides:          gldb
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Should-Start:      $network
# Should-Stop:       $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start and stop the Galera Load Balancer daemon
# Description:       GLB is a TCP load balancer similar to Pen.
### END INIT INFO


prog="glbd"
proc=glbd
NAME=glbd
DAEMON=/usr/sbin/glbd
EXEC_PATH=/usr/local/sbin:/usr/sbin
PID_FILE="/var/run/glbd.pid"
CONTROL_FIFO="/var/run/glbd.fifo"
THREADS=4

if [ -f /etc/default/glb ]; then
        . /etc/default/glb
fi

if [ "$START" != "yes" ]; then
  echo "To enable $NAME, edit /etc/default/glb and set START=yes"
  exit 0
fi

test -x $DAEMON || exit 0

LISTEN_PORT=$(echo $LISTEN_ADDR | awk -F ':' '{ print $2 }')
[ -z "$LISTEN_PORT" ] && LISTEN_PORT=$LISTEN_ADDR

if [ -n "$CONTROL_ADDR" ]; then
	CONTROL_PORT=$(echo $CONTROL_ADDR | awk -F ':' '{ print $2 }')
	if [ -n "$CONTROL_PORT" ]; then # CONTROL_ADDR has both address and port
		CONTROL_IP=$(echo $CONTROL_ADDR | awk -F ':' '{ print $1 }')
	else                            # CONTROL_ADDR contains only port
		CONTROL_PORT=$CONTROL_ADDR
		CONTROL_IP="127.0.0.1"
	fi
else
	CONTROL_IP=""
	CONTROL_PORT=""
fi

wait_for_connections_to_drop() {
	while (netstat -na | grep -m 1 ":$LISTEN_PORT " > /dev/null); do
		echo "[`date`] $prog: waiting for lingering sockets to clear up..."
		sleep 1s
	done;
	return 0
}

stop() {
	[ -f "$PID_FILE" ] && PID=$(cat $PID_FILE) || PID=""
	if [ -z "$PID" ]; then
		echo "No valid PID file found at '$PID_FILE'"
		return
	fi
	echo -n "[`date`] $prog: stopping... "
	kill $PID > /dev/null
	if [ $? -ne 0 ]; then
		echo "failed."
		return
	fi
	echo "done."
	rm $PID_FILE
	rm $CONTROL_FIFO
}

start() {
	exec=$( PATH=$EXEC_PATH:/usr/bin:/bin which $prog | \
	        grep -E $(echo $EXEC_PATH | sed 's/:/|/') )
	if [ -z "$exec" ]; then
		echo "[`date`] '$prog' not found in $EXEC_PATH."
		exit 1
	fi
	[ -f "$PID_FILE" ] && PID=$(cat $PID_FILE) || PID=""
	if [ -n "$PID" ] ; then
		echo "[`date`] $prog: already running (PID: $PID)...";
		exit 1
	fi
	if [ -z "$LISTEN_PORT" ]; then
		echo "[`date`] $prog: no port to listen at, check configuration.";
		exit 1
	fi
	echo "[`date`] $prog: starting..."
	wait_for_connections_to_drop
	rm -rf $CONTROL_FIFO > /dev/null
	GLBD_OPTIONS="--fifo=$CONTROL_FIFO --threads=$THREADS --daemon $OTHER_OPTIONS"
	[ -n "$MAX_CONN" ] && GLBD_OPTIONS="$GLBD_OPTIONS --connections=$MAX_CONN"
	[ -n "$CONTROL_ADDR" ] && GLBD_OPTIONS="$GLBD_OPTIONS --control=$CONTROL_ADDR"
	eval $exec $GLBD_OPTIONS $LISTEN_ADDR $DEFAULT_TARGETS
	PID=`pidof $exec`
	if [ $? -ne 0 ]; then
		echo "[`date`] $prog: failed to start."
		exit 1
	fi
	echo "[`date`] $prog: started, pid=$PID"
	echo $PID > "$PID_FILE"
	exit 0
}

restart() {
	echo "[`date`] $prog: restarting..."
	stop
	start
}

getinfo() {
	if [ -z "$CONTROL_PORT" ]; then
		echo "Port for control communication is not configured."
		exit 1
	fi
	echo getinfo | nc -q1 $CONTROL_IP $CONTROL_PORT && exit 0
	echo "[`date`] $prog: failed to query 'getinfo' from '$CONTROL_ADDR'"
	exit 1
}

getstats() {
	if [ -z "$CONTROL_PORT" ]; then
		echo "Port for control communication is not configured."
		exit 1
	fi
	echo getstats | nc -q1 $CONTROL_IP $CONTROL_PORT && exit 0
	echo "[`date`] $prog: failed to query 'getstats' from '$CONTROL_ADDR'"
	exit 1
}

add() {
	if [ -z "$CONTROL_PORT" ]; then
		echo "Port for control communication is not configured."
		exit 1
	fi
	if [ "$1" = "" ]; then
		echo "Usage: $0 add <ip>:<port>[:<weight>]"
		exit 1
	fi
	if [ "`echo "$1" | nc -q1 $CONTROL_IP $CONTROL_PORT`" = "Ok" ]; then
		echo "[`date`] $prog: added '$1' successfully"
		#getinfo
		exit 0
	fi
	echo "[`date`] $prog: failed to add target '$1'."
	exit 1
}

remove() {
	if [ -z "$CONTROL_PORT" ]; then
		echo "Port for control communication is not configured."
		exit 1
	fi
	if [ "$1" = "" ]; then
		echo "Usage: $0 remove <ip>:<port>"
		exit 1
	fi
	if [ "`echo "$1:-1" | nc -q1 $CONTROL_IP $CONTROL_PORT`" = "Ok" ]; then
		echo "[`date`] $prog: removed '$1' successfully"
		#getinfo
		exit 0
	fi
	echo "[`date`] $prog: failed to remove target '$1'."
	exit 1
}

drain() {
	if [ -z "$CONTROL_PORT" ]; then
		echo "Port for control communication is not configured."
		exit 1
	fi
	if [ "$1" = "" ]; then
		echo "Usage: $0 drain <ip>:<port>"
		exit 1
	fi
	if [ "`echo "$1:0" | nc -q1 $CONTROL_IP $CONTROL_PORT`" = "Ok" ]; then
		echo "[`date`] $prog: '$1' was set to drain connections"
		#getinfo
		exit 0
	fi
	echo "[`date`] $prog: failed to set '$1' to drain."
	exit 1
}

case $1 in
	start)
		start
	;;
	stop)
		stop
	;;
	restart)
		restart
	;;
	getinfo)
		getinfo
	;;
	getstats)
		getstats
	;;
	status)
		getinfo
	;;
	add)
		add $2
	;;
	remove)
		remove $2
	;;
	drain)
		drain $2
	;;
	*)
		echo $"Usage: $0 {start|stop|restart|status|getstats|getinfo|add|remove|drain}"
	exit 2
esac
