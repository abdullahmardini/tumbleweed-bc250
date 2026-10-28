#!/bin/bash
# Test bc250-nct6687-kmp-default: PWM write on fan2, then hand back to firmware.
# Run as root. Does not reboot, does not touch the initrd.
# INSTALL_RPM=1 RPM=path/to/bc250-nct6687-kmp-default-*.rpm installs first.
set -euo pipefail

RPM=${RPM:-}
FAN=2                # the board's cooling fan is on fan2 (pump header)
PWM_FULL=255
PWM_LOW=77           # ~30 %, short enough at idle to be harmless
SETTLE_SECONDS=10
PWM_ENABLE_MANUAL=1
PWM_ENABLE_AUTO=2

# stderr, so debug lines still show inside $(...)
debug() {
	echo "[$(date +%T)] DEBUG: $*" >&2
}

hw=""
restore() {
	local status=$?
	debug "exit trap: status=$status hw=${hw:-<none>}"
	# Whatever failed, give the fan back to the firmware curve.
	if [ -n "$hw" ] && [ -w "$hw/pwm${FAN}_enable" ]; then
		debug "writing $PWM_ENABLE_AUTO to $hw/pwm${FAN}_enable"
		echo "$PWM_ENABLE_AUTO" > "$hw/pwm${FAN}_enable" || debug "restore write failed"
	fi
	[ "$status" -eq 0 ] || echo "FAILED (exit $status); fan${FAN} set back to automatic" >&2
}
trap restore EXIT
trap 'debug "command failed (exit $?) at line $LINENO: $BASH_COMMAND"' ERR

# Both drivers name the hwmon after the chip (nct6686), so match on the
# driver bound to the device instead.
find_hwmon_by_driver() {
	local h driver
	debug "looking for hwmon bound to driver $1"
	for h in /sys/class/hwmon/hwmon*; do
		driver=$(basename "$(readlink -f "$h/device/driver")")
		debug "  $h name=$(cat "$h/name") driver=$driver"
		if [ "$driver" = "$1" ]; then
			debug "  match: $h"
			echo "$h"
			return 0
		fi
	done
	echo "no hwmon bound to driver $1" >&2
	return 1
}

show() {
	debug "$1: enable=$(cat "$hw/pwm${FAN}_enable") pwm=$(cat "$hw/pwm${FAN}") rpm=$(cat "$hw/fan${FAN}_input")"
}

debug "start: kernel $(uname -r), loaded: $(lsmod | awk '/^nct668/ {print $1}' | tr '\n' ' ')"

if [ "${INSTALL_RPM:-0}" = 1 ]; then
	[ -n "$RPM" ] || { echo "INSTALL_RPM=1 needs RPM=path" >&2; exit 1; }
	debug "installing $RPM"
	zypper --non-interactive install --allow-unsigned-rpm "$RPM"
else
	debug "skipping install (INSTALL_RPM=1 to enable)"
fi

# Only one driver can hold the chip's I/O region.
if lsmod | grep -q '^nct6683 '; then
	debug "unloading nct6683"
	modprobe -r nct6683
else
	debug "nct6683 not loaded"
fi
debug "loading nct6687 (options: $(grep -h '^options nct6687' /usr/lib/modprobe.d/*.conf /etc/modprobe.d/*.conf 2>/dev/null || echo none))"
modprobe nct6687
debug "loaded: $(lsmod | awk '/^nct668/ {print $1}' | tr '\n' ' ')"

hw=$(find_hwmon_by_driver nct6687)
echo "hwmon: $hw"
ls -l "$hw/pwm${FAN}" "$hw/pwm${FAN}_enable"

show "before"
debug "set manual, pwm=$PWM_FULL"
echo "$PWM_ENABLE_MANUAL" > "$hw/pwm${FAN}_enable"
echo "$PWM_FULL" > "$hw/pwm${FAN}"
debug "waiting ${SETTLE_SECONDS}s"
sleep "$SETTLE_SECONDS"
show "full"

debug "set pwm=$PWM_LOW"
echo "$PWM_LOW" > "$hw/pwm${FAN}"
debug "waiting ${SETTLE_SECONDS}s"
sleep "$SETTLE_SECONDS"
show "low"

debug "set automatic"
echo "$PWM_ENABLE_AUTO" > "$hw/pwm${FAN}_enable"
debug "waiting ${SETTLE_SECONDS}s"
sleep "$SETTLE_SECONDS"
show "auto"

hw=""
debug "unloading nct6687, reloading nct6683"
modprobe -r nct6687
modprobe nct6683
debug "loaded: $(lsmod | awk '/^nct668/ {print $1}' | tr '\n' ' ')"
debug "waiting ${SETTLE_SECONDS}s"
sleep "$SETTLE_SECONDS"
hw683=$(find_hwmon_by_driver nct6683)
debug "unloaded: nct6683 pwm=$(cat "$hw683/pwm${FAN}") rpm=$(cat "$hw683/fan${FAN}_input")"
debug "kernel log:"
journalctl -k -b --no-pager | grep -i nct6687 | tail -5 || true
debug "done"
