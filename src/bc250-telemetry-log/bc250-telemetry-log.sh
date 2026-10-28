#!/usr/bin/bash
# bc250-telemetry-log: append one CSV row of BC-250 temperatures, power,
# clocks and fan state every INTERVAL_S seconds, one file per day.
#
# Reads plain sysfs only. Every amdgpu hwmon value, pp_dpm_sclk and a live
# gpu_metrics read make amdgpu send TransferTableSmu2Dram on MP1 C2PMSG_66,
# which is the governor's "queue 0" (0x03B10A08) that it drives directly,
# outside amdgpu's lock (cyan_skillfish_ppt.c, governor src/smu/mod.rs).
# So by default amdgpu data comes only from gpu_metrics while the governor's
# tmpfs copy is bind-mounted over it (no SMU message per read).
# BC250_TELEMETRY_SMU_READS=1 also reads the SMU-backed files.
#
# Environment (tests and overrides; defaults in brackets):
#   BC250_TELEMETRY_SYSFS     sysfs root [/sys]
#   BC250_TELEMETRY_PROC      procfs root [/proc]
#   BC250_TELEMETRY_DIR       output directory [/var/log/bc250]
#   BC250_TELEMETRY_INTERVAL  seconds between rows [INTERVAL_S]
#   BC250_TELEMETRY_SAMPLES   stop after this many rows, 0 = never [0]
#   BC250_TELEMETRY_SMU_READS 1 = also read SMU-backed amdgpu files [0]
set -euo pipefail

readonly INTERVAL_S=10
# Disk cap: about 2-3 MB per day at 10 s, so both limits sit near 100 MiB.
readonly KEEP_DAYS=45
readonly MAX_TOTAL_MIB=128
readonly SECONDS_PER_DAY=86400
readonly FILE_PREFIX=telemetry-
# hwmon names this board should have (HANDOFF Sensors). nct6683 and nct6687
# both register as nct6686.
readonly EXPECTED_HWMON=(amdgpu k10temp nvme nct6686)
# gpu_metrics v2.2 (kgd_pp_interface.h): 128 bytes, format 2, content 2.
readonly GM_SIZE=128
readonly GM_REVISION=514 # 0x0202 as u16 little endian
readonly GM_INVALID=65535
# u16 indexes into gpu_metrics_v2_2 (byte offset / 2).
readonly GM_TEMP_GFX=2      # 0x04 centi-degC
readonly GM_TEMP_SOC=3      # 0x06 centi-degC
readonly GM_GFX_ACTIVITY=14 # 0x1C centi-percent, patched by the governor
readonly GM_CLOCK_COUNTER=16 # 0x20 u64 boottime ns, 4 words
readonly GM_SOCKET_POWER=20 # 0x28 mW, whole APU (PPT)
readonly GM_SOC_POWER=22    # 0x2C mW, VDDCR_VDD = CPU core rail
readonly GM_GFX_POWER=23    # 0x2E mW, VDDCR_GFX
readonly GM_AVG_GFXCLK=32   # 0x40 MHz
readonly GM_CUR_GFXCLK=38   # 0x4C MHz, wrong on 8-core boards
readonly GM_CUR_SOCCLK=39   # 0x4E MHz
readonly GM_CUR_UCLK=40     # 0x50 MHz
readonly GM_CUR_FCLK=41     # 0x52 MHz
readonly GM_THROTTLE=54     # 0x6C u32, 2 words
readonly GM_FIELDS=("$GM_TEMP_GFX" "$GM_TEMP_SOC" "$GM_GFX_ACTIVITY"
    "$GM_SOCKET_POWER" "$GM_SOC_POWER" "$GM_GFX_POWER" "$GM_AVG_GFXCLK"
    "$GM_CUR_GFXCLK" "$GM_CUR_SOCCLK" "$GM_CUR_UCLK" "$GM_CUR_FCLK")
readonly GM_COLUMNS=(gpu_temp_gfx_cC gpu_temp_soc_cC gpu_activity_cpct
    apu_power_mW cpu_rail_power_mW gfx_rail_power_mW gfxclk_avg_MHz
    gfxclk_cur_MHz socclk_MHz uclk_MHz fclk_MHz)

SYSFS=${BC250_TELEMETRY_SYSFS:-/sys}
PROC=${BC250_TELEMETRY_PROC:-/proc}
OUT_DIR=${BC250_TELEMETRY_DIR:-/var/log/bc250}
INTERVAL=${BC250_TELEMETRY_INTERVAL:-$INTERVAL_S}
SAMPLES=${BC250_TELEMETRY_SAMPLES:-0}
SMU_READS=${BC250_TELEMETRY_SMU_READS:-0}

# journald reads "<N>" as the syslog priority; on a terminal print plain text.
# JOURNAL_STREAM is inherited by children, so check that stderr is that stream.
if [[ -n ${JOURNAL_STREAM:-} ]] &&
    [[ $(stat -L -c '%d:%i' /proc/$$/fd/2 2>/dev/null) == "$JOURNAL_STREAM" ]]; then
    P_ERR='<3>' P_WARN='<4>' P_INFO='<6>'
else
    P_ERR='error: ' P_WARN='warning: ' P_INFO=''
fi
err() { printf '%s%s\n' "$P_ERR" "$*" >&2; }
warn() { printf '%s%s\n' "$P_WARN" "$*" >&2; }
info() { printf '%s%s\n' "$P_INFO" "$*" >&2; }

for n in INTERVAL SAMPLES SMU_READS; do
    if [[ ! ${!n} =~ ^[0-9]+$ ]]; then
        err "$n must be a non-negative integer, got '${!n}'"
        exit 2
    fi
done
if ((INTERVAL < 1)); then
    err "interval must be at least 1 s"
    exit 2
fi

# A failing read is logged once when it starts failing and once when it
# recovers, so a dead sensor neither floods the journal nor goes unnoticed.
declare -A FAILING=()
fail_once() { # key message
    if [[ -z ${FAILING[$1]:-} ]]; then
        FAILING[$1]=1
        warn "$2"
    fi
}
recovered() { # key message
    if [[ -n ${FAILING[$1]:-} ]]; then
        unset 'FAILING[$1]'
        info "$2"
    fi
}

# read_value FILE: sets VALUE to the first line, or empty on failure.
VALUE=
read_value() {
    VALUE=
    # read returns 1 at EOF without a newline but still fills VALUE.
    if { read -r VALUE <"$1"; } 2>/dev/null || [[ -n $VALUE ]]; then
        recovered "$1" "$1 readable again"
        return 0
    fi
    VALUE=
    fail_once "$1" "cannot read $1; logging an empty field until it recovers"
    return 1
}

slug() { # lower-case label with runs of other characters turned into _
    local s=${1,,}
    s=${s//[^a-z0-9]/_}
    while [[ $s == *__* ]]; do s=${s//__/_}; done
    s=${s#_}
    printf '%s' "${s%_}"
}

# ---- discovery (once per start; hwmon numbers change between boots) ----
COLS=(time epoch_s)
# hwmon channels: header names and files, appended after the amdgpu columns.
HW_COLS=()
FILES=()
declare -A FOUND=()
AMDGPU_DEV=

add_channels() { # hwmon_dir column_prefix
    local dir=$1 prefix=$2 f base label unit
    for f in "$dir"/temp*_input "$dir"/fan*_input "$dir"/pwm[0-9] "$dir"/pwm[0-9][0-9]; do
        [[ -e $f ]] || continue
        base=${f##*/}
        base=${base%_input}
        case $base in
            temp*) unit=mC ;;
            fan*) unit=rpm ;;
            pwm*) unit=raw ;;
        esac
        label=
        if [[ -e $dir/${base}_label ]] && read_value "$dir/${base}_label"; then
            label=_$(slug "$VALUE")
        fi
        HW_COLS+=("${prefix}_${base}${label}_${unit}")
        FILES+=("$f")
    done
}

if [[ ! -d $SYSFS/class/hwmon ]]; then
    err "$SYSFS/class/hwmon does not exist; nothing to log"
    exit 1
fi

declare -A NVME=() # controller name -> hwmon dir
for hw in "$SYSFS"/class/hwmon/hwmon*; do
    [[ -e $hw/name ]] || continue
    read_value "$hw/name" || continue
    name=$VALUE
    case $name in
        amdgpu | k10temp | nct6686)
            if [[ -n ${FOUND[$name]:-} ]]; then
                warn "second $name hwmon $hw ignored; logging ${FOUND[$name]}"
                continue
            fi
            FOUND[$name]=$hw
            ;;
        nvme)
            FOUND[$name]=$hw
            # Named after the controller (nvme0), which outlives hwmon numbering.
            ctrl=$(readlink "$hw/device") || ctrl=${hw##*/}
            NVME[${ctrl##*/}]=$hw
            ;;
    esac
done

# Fixed source order keeps the header the same when hwmon numbers move.
[[ -z ${FOUND[amdgpu]:-} ]] || AMDGPU_DEV=${FOUND[amdgpu]}/device
[[ -z ${FOUND[k10temp]:-} ]] || add_channels "${FOUND[k10temp]}" k10temp
[[ -z ${FOUND[nct6686]:-} ]] || add_channels "${FOUND[nct6686]}" nct6686
if ((${#NVME[@]})); then
    mapfile -t ctrls < <(printf '%s\n' "${!NVME[@]}" | sort -V)
    for ctrl in "${ctrls[@]}"; do add_channels "${NVME[$ctrl]}" "$ctrl"; done
fi

for name in "${EXPECTED_HWMON[@]}"; do
    if [[ -z ${FOUND[$name]:-} ]]; then
        case $name in
            nct6686) hint=" (is nct6683 loaded with force=1, or nct6687?)" ;;
            *) hint= ;;
        esac
        warn "expected hwmon '$name' not found under $SYSFS/class/hwmon$hint; its columns are left out"
    else
        info "hwmon $name: ${FOUND[$name]}"
    fi
done

# gpu_metrics columns stay in the header whether or not the file exists, so
# files from different boots line up.
GM_FILE=
GM_MOUNT=
if [[ -n $AMDGPU_DEV ]]; then
    GM_FILE=$AMDGPU_DEV/gpu_metrics
    if [[ ! -e $GM_FILE ]]; then
        warn "$GM_FILE missing; gpu_metrics columns stay empty"
        GM_FILE=
    else
        # The governor bind-mounts over the resolved path, so compare that
        # with mountinfo's mount point (relative to the sysfs root for tests).
        GM_MOUNT=$(realpath -e "$GM_FILE")
        GM_MOUNT=/sys${GM_MOUNT#"$(realpath -e "$SYSFS")"}
    fi
fi
COLS+=(gpu_metrics_src gpu_metrics_age_ms "${GM_COLUMNS[@]}" throttle_status)

SMU_FILES=()
if ((SMU_READS)) && [[ -n $AMDGPU_DEV ]]; then
    warn "BC250_TELEMETRY_SMU_READS=1: each row makes amdgpu send SMU messages on the mailbox the governor also drives"
    for pair in power1_average:amdgpu_power1_average_uW temp1_input:amdgpu_temp1_edge_mC freq1_input:amdgpu_freq1_sclk_Hz; do
        f=${FOUND[amdgpu]}/${pair%%:*}
        if [[ -e $f ]]; then
            COLS+=("${pair#*:}")
            SMU_FILES+=("$f")
        else
            warn "$f missing; column ${pair#*:} left out"
        fi
    done
    if [[ -e $AMDGPU_DEV/pp_dpm_sclk ]]; then
        COLS+=(pp_dpm_sclk_cur_MHz)
    else
        warn "$AMDGPU_DEV/pp_dpm_sclk missing; column left out"
    fi
fi

# gpu_busy_percent has no Cyan Skillfish sensor (read_sensor returns
# EOPNOTSUPP before any SMU message), so it is probed once and dropped.
BUSY_FILE=
if [[ -n $AMDGPU_DEV ]]; then
    if { read -r VALUE <"$AMDGPU_DEV/gpu_busy_percent"; } 2>/dev/null; then
        BUSY_FILE=$AMDGPU_DEV/gpu_busy_percent
        COLS+=(gpu_busy_percent)
    else
        warn "$AMDGPU_DEV/gpu_busy_percent unreadable (no GPU load sensor on Cyan Skillfish); column left out, see gpu_activity_cpct"
    fi
fi

COLS+=("${HW_COLS[@]}")
OFS=,
HEADER=$(IFS=$OFS; printf '%s' "${COLS[*]}")

# ---- output files ----
if ! mkdir -p "$OUT_DIR" 2>/dev/null || [[ ! -w $OUT_DIR ]]; then
    err "output directory $OUT_DIR is not writable"
    exit 1
fi

prune() { # keep_path: delete files past KEEP_DAYS, then oldest past MAX_TOTAL_MIB
    local keep=$1 cutoff f total=0 sizes
    local -a files=()
    printf -v cutoff '%(%F)T' $((EPOCHSECONDS - KEEP_DAYS * SECONDS_PER_DAY))
    for f in "$OUT_DIR/$FILE_PREFIX"*.csv; do
        [[ -e $f ]] || continue
        local day=${f##*/"$FILE_PREFIX"}
        day=${day:0:10}
        if [[ $f != "$keep" && $day < $cutoff ]]; then
            rm -f -- "$f" && info "removed $f (older than $KEEP_DAYS days)"
            continue
        fi
        files+=("$f")
    done
    ((${#files[@]})) || return 0
    mapfile -t sizes < <(stat -c %s -- "${files[@]}")
    for f in "${sizes[@]}"; do total=$((total + f)); done
    local i=0 limit=$((MAX_TOTAL_MIB * 1024 * 1024))
    # Globs sort by name, and names start with the date, so oldest first.
    while ((total > limit && i < ${#files[@]})); do
        if [[ ${files[i]} != "$keep" ]]; then
            rm -f -- "${files[i]}" && info "removed ${files[i]} (cap $MAX_TOTAL_MIB MiB)"
            total=$((total - sizes[i]))
        fi
        i=$((i + 1))
    done
}

CUR_DAY=
CUR_FILE=
open_day() { # day
    local f=$OUT_DIR/$FILE_PREFIX$1.csv first
    # A changed column set (other sensor driver, SMU reads toggled) starts a
    # new file so every file has one header.
    if [[ -s $f ]]; then
        first=
        { read -r first <"$f"; } 2>/dev/null || :
        if [[ $first != "$HEADER" ]]; then
            printf -v f '%s/%s%s-%(%H%M%S)T.csv' "$OUT_DIR" "$FILE_PREFIX" "$1" -1
            info "columns differ from today's file; writing $f"
        fi
    fi
    CUR_DAY=$1
    CUR_FILE=$f
    info "writing $CUR_FILE every $INTERVAL s"
    prune "$CUR_FILE"
}

# ---- sampling ----
gm_source() { # sets GM_SRC: overlay (governor copy), live, or missing
    GM_SRC=missing
    [[ -n $GM_FILE ]] || return 0
    GM_SRC=live
    local line fields
    while read -r line; do
        read -ra fields <<<"$line"
        if [[ ${fields[4]} == "$GM_MOUNT" ]]; then
            GM_SRC=overlay
            return 0
        fi
    done <"$PROC/self/mountinfo"
}

uptime_ms() { # sets UPTIME_MS from /proc/uptime (boottime, like the counter)
    UPTIME_MS=
    read_value "$PROC/uptime" || return 0
    local up=${VALUE%% *}
    UPTIME_MS=$((10#${up%.*} * 1000 + 10#${up#*.} * 10))
}

ROW=()
sample_gpu_metrics() {
    local -a w=()
    local raw i
    gm_source
    ROW+=("$GM_SRC")
    if [[ $GM_SRC == overlay ]] || { [[ $GM_SRC == live ]] && ((SMU_READS)); }; then
        if raw=$(od -An -v -tu2 -N "$GM_SIZE" -- "$GM_FILE" 2>/dev/null); then
            recovered "$GM_FILE" "$GM_FILE readable again"
            read -ra w <<<"${raw//$'\n'/ }"
        else
            fail_once "$GM_FILE" "cannot read $GM_FILE; gpu_metrics columns empty until it recovers"
        fi
    elif [[ $GM_SRC == live ]]; then
        fail_once gm-live "gpu_metrics is not the governor's copy (governor stopped, or fix-metrics off); not reading it, to keep SMU traffic off its mailbox"
    fi
    if ((${#w[@]} == GM_SIZE / 2)) && ((w[0] == GM_SIZE && w[1] == GM_REVISION)); then
        recovered gm-format "gpu_metrics format is v2.2 again"
        uptime_ms
        local ns=$(((w[GM_CLOCK_COUNTER + 3] << 48) | (w[GM_CLOCK_COUNTER + 2] << 32) |
            (w[GM_CLOCK_COUNTER + 1] << 16) | w[GM_CLOCK_COUNTER]))
        if [[ -n $UPTIME_MS ]]; then
            ROW+=("$((UPTIME_MS - ns / 1000000))")
        else
            ROW+=("")
        fi
        for i in "${GM_FIELDS[@]}"; do
            if ((w[i] == GM_INVALID)); then ROW+=(""); else ROW+=("${w[i]}"); fi
        done
        ROW+=("$(((w[GM_THROTTLE + 1] << 16) | w[GM_THROTTLE]))")
        return 0
    fi
    if ((${#w[@]})); then
        fail_once gm-format "$GM_FILE is not gpu_metrics v2.2 (size ${w[0]}, revision ${w[1]}); columns empty"
    fi
    for ((i = 0; i < ${#GM_FIELDS[@]} + 2; i++)); do ROW+=(""); done
}

sample_row() {
    local f line
    ROW=()
    printf -v line '%(%FT%T%z)T' "$EPOCHSECONDS"
    ROW+=("$line" "$EPOCHSECONDS")
    sample_gpu_metrics
    for f in "${SMU_FILES[@]}"; do
        read_value "$f" || :
        ROW+=("$VALUE")
    done
    if ((SMU_READS)) && [[ -n $AMDGPU_DEV && -e $AMDGPU_DEV/pp_dpm_sclk ]]; then
        local cur=
        if { while read -r line; do
            # "1: 100Mhz *" marks the current level.
            if [[ $line == *'*' ]]; then
                cur=${line#*: }
                cur=${cur%%[Mm]hz*}
            fi
        done <"$AMDGPU_DEV/pp_dpm_sclk"; } 2>/dev/null; then
            recovered pp_dpm_sclk "pp_dpm_sclk readable again"
        else
            fail_once pp_dpm_sclk "cannot read $AMDGPU_DEV/pp_dpm_sclk"
        fi
        ROW+=("$cur")
    fi
    if [[ -n $BUSY_FILE ]]; then
        read_value "$BUSY_FILE" || :
        ROW+=("$VALUE")
    fi
    for f in "${FILES[@]}"; do
        read_value "$f" || :
        ROW+=("$VALUE")
    done
}

trap 'info "stopping"; exit 0' TERM INT

count=0
while :; do
    printf -v today '%(%F)T' "$EPOCHSECONDS"
    [[ $today == "$CUR_DAY" ]] || open_day "$today"
    sample_row
    if ((${#ROW[@]} != ${#COLS[@]})); then
        err "internal error: ${#ROW[@]} values for ${#COLS[@]} columns"
        exit 1
    fi
    line=$(IFS=$OFS; printf '%s' "${ROW[*]}")
    # Checked per row so a deleted or truncated file gets its header back.
    if [[ -s $CUR_FILE ]]; then
        out=$line
    else
        out=$HEADER$'\n'$line
    fi
    if { printf '%s\n' "$out" >>"$CUR_FILE"; } 2>/dev/null; then
        recovered write "writing $CUR_FILE again"
    else
        fail_once write "cannot write $CUR_FILE; rows are lost until it recovers"
    fi
    count=$((count + 1))
    if ((SAMPLES && count >= SAMPLES)); then
        break
    fi
    # sleep in the background so SIGTERM is handled at once, not after it.
    sleep "$INTERVAL" &
    wait $! || :
done
