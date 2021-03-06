#!/bin/sh
:

# shellcheck disable=SC2039
clone-help()
{
	echo "pot clone [-hvF] -p potname -P basepot [-i ipaddr]"
	echo '  -h print this help'
	echo '  -v verbose'
	echo '  -P potname : the pot to be cloned (template)'
	echo '  -p potname : the new pot name'
	echo '  -N network-type : new network type of the cloned pot'
	echo '  -i ipaddr : an ip address or the keyword auto (if applicable)'
	echo '  -B bridge-name : the name of the bridge to be used (private-bridge only)'
	echo '  -S network-stack : the network stack (ipv4, ipv6 or dual)'
	echo '  -F : automatically take snapshots of dataset that has no one'
}

# $1 pot name
_cj_cleanup()
{
	# shellcheck disable=SC2039
	local _pname _jdset
	_pname=$1
	_jdset=${POT_ZFS_ROOT}/jails/$_pname
	if [ -z "$_pname" ]; then
		return
	fi
	zfs destroy -r "$_jdset" 2> /dev/null
}

# $1 pot name
# $2 pot-base name
# $3 auto-snapshot
_cj_zfs()
{
	# shellcheck disable=SC2039
	local _pname _potbase _jdset _pdir _pbdir _pbdset _mnt_p _opt _autosnap _snaptag _pb_type
	_pname=$1
	_potbase=$2
	_autosnap="${3:-NO}"
	_jdset=${POT_ZFS_ROOT}/jails/$_pname
	_pbdset=${POT_ZFS_ROOT}/jails/$_potbase
	_pdir=${POT_FS_ROOT}/jails/$_pname
	_pbdir=${POT_FS_ROOT}/jails/$_potbase
	_pb_type="$( _get_conf_var "$_potbase" pot.type )"
	# Create the main jail zfs dataset
	if ! _zfs_dataset_valid "$_jdset" ; then
		zfs create "$_jdset"
	else
		_info "$_jdset exists already"
	fi
	# Create the conf directory
	if [ ! -d "$_pdir/conf" ]; then
		_debug "Create conf dir ($_pdir/conf)"
		mkdir -p "$_pdir/conf"
	fi
	if [ -e "$_pdir/conf/fscomp.conf" ]; then
		rm -f "$_pdir/conf/fscomp.conf"
	fi
	if [ "$_pb_type" = "single" ]; then
		_dset="${_pbdset}/m"
		_snap=$( _zfs_last_snap "$_dset" )
		if [ -z "$_snap" ]; then
			if [ "$_autosnap" = "YES" ]; then
				_snaptag="$(date +%s)"
				_info "$_dset has no snap - taking a snapshot on the fly with tag $_snaptag"
				zfs snapshot "${_dset}@${_snaptag}"
				_snap=$_snaptag
			else
				_error "$_dset has no snap - please take a snapshot of $_potbase"
				_cj_cleanup "$_pname"
				return 1 # error
			fi
		fi
		_debug "clone $_dset@$_snap into $_jdset/m"
		zfs clone -o mountpoint="$_pdir/m" "$_dset@$_snap" "$_jdset/m"
		touch "$_pdir/conf/fscomp.conf"
		while read -r line ; do
			_dset=$( echo "$line" | awk '{print $1}' )
			_mnt_p=$( echo "$line" | awk '{print $2}' )
			_opt=$( echo "$line" | awk '{print $3}' )
			# ro components are replicated "as is"
			if [ "$_opt" = ro ] ; then
				_debug "$_dset ${_pdir}/${_mnt_p##${_pbdir}/} $_opt"
				echo "$_dset ${_pdir}/${_mnt_p##${_pbdir}/} $_opt" >> "$_pdir/conf/fscomp.conf"
			else
				# managing fscomp datasets - the simple way - no clone support for fscomp
				if [ "$_dset" != "${_dset##${POT_ZFS_ROOT}/fscomp}" ]; then
					_debug "$_dset $_pdir/${_mnt_p##${_pbdir}/}"
					echo "$_dset $_pdir/${_mnt_p##${_pbdir}/}" >> "$_pdir/conf/fscomp.conf"
				else
					_error "not able to manage $_dset"
				fi
			fi
		done < "${_pbdir}/conf/fscomp.conf"
	elif [ "$_pb_type" = "multi" ]; then
		# Create the root mountpoint
		if [ ! -d "$_pdir/m" ]; then
			_debug "Create root mountpoint dir ($_pdir/m)"
			mkdir -p "$_pdir/m"
		fi
		while read -r line ; do
			_dset=$( echo "$line" | awk '{print $1}' )
			_mnt_p=$( echo "$line" | awk '{print $2}' )
			_opt=$( echo "$line" | awk '{print $3}' )
			# ro components are replicated "as is"
			if [ "$_opt" = ro ] ; then
				_debug "$_dset ${_pdir}/${_mnt_p##${_pbdir}/} $_opt"
				echo "$_dset ${_pdir}/${_mnt_p##${_pbdir}/} $_opt" >> "$_pdir/conf/fscomp.conf"
			else
				# managing potbase datasets
				if [ "$_dset" != "${_dset##${_pbdset}}" ]; then
					_dname="${_dset##${_pbdset}/}"
					_snap=$( _zfs_last_snap "$_dset" )
					if [ -z "$_snap" ]; then
						if [ "$_autosnap" = "YES" ]; then
							_snaptag="$(date +%s)"
							_info "$_dset has no snap - taking a snapshot on the fly with tag $_snaptag"
							zfs snapshot "${_dset}@${_snaptag}"
							_snap=$_snaptag
						else
							_error "$_dset has no snap - please take a snapshot of $_potbase"
							_cj_cleanup "$_pname"
							return 1
						fi
					fi
					if _zfs_exist "$_jdset/$_dname" "$_pdir/$_dname" ; then
						_debug "$_dname dataset already cloned"
					else
						_debug "clone $_dset@$_snap into $_jdset/$_dname"
						zfs clone -o mountpoint="$_pdir/$_dname" "$_dset@$_snap" "$_jdset/$_dname"
						if [ -z "$_opt" ]; then
							_debug "$_jdset/$_dname $_pdir/${_mnt_p##${_pbdir}/}"
							echo "$_jdset/$_dname $_pdir/${_mnt_p##${_pbdir}/}" >> "$_pdir/conf/fscomp.conf"
						else
							_debug "$_jdset/$_dname $_pdir/${_mnt_p##${_pbdir}/} $_opt"
							echo "$_jdset/$_dname $_pdir/${_mnt_p##${_pbdir}/} $_opt" >> "$_pdir/conf/fscomp.conf"
						fi
					fi
				# managing fscomp datasets - the simple way - no clone support for fscomp
				elif [ "$_dset" != "${_dset##${POT_ZFS_ROOT}/fscomp}" ]; then
					_debug "$_dset $_pdir/${_mnt_p##${_pbdir}/}"
					echo "$_dset $_pdir/${_mnt_p##${_pbdir}/}" >> "$_pdir/conf/fscomp.conf"
				else
					_error "not able to manage $_dset"
				fi
			fi
		done < "${POT_FS_ROOT}/jails/$_potbase/conf/fscomp.conf"
	fi
	return 0 # true
}

# $1 pot name
# $2 pot-base name
# $3 network type
# $4 ip
# $5 bridge name
# $6 network stack
_cj_conf()
{
	# shellcheck disable=SC2039
	local _pname _potbase _ip _network_type _bridge_name _stack
	_pname=$1
	_potbase=$2
	_network_type=$3
	_ip=$4
	_bridge_name=$5
	_stack=$6
	_pdir=${POT_FS_ROOT}/jails/$_pname
	_pbdir=${POT_FS_ROOT}/jails/$_potbase
	if [ ! -d "$_pdir/conf" ]; then
		mkdir -p "$_pdir/conf"
	fi
	grep -vE '^(host.hostname|bridge|ip|vnet|network_type|pot.stack)' "$_pbdir/conf/pot.conf" > "$_pdir/conf/pot.conf"
	{
		echo "host.hostname=\"$( _get_usable_hostname "${_pname}" )\""
		echo "pot.stack=$_stack"
		echo "network_type=$_network_type"
		case "$_network_type" in
		"inherit")
			echo "vnet=false"
			;;
		"alias")
			echo "vnet=false"
			echo "ip=$_ip"
			;;
		"public-bridge")
			echo "vnet=true"
			echo "ip=$_ip"
			;;
		"private-bridge")
			echo "vnet=true"
			echo "ip=$_ip"
			echo "bridge=$_bridge_name" >> "$_pdir/conf/pot.conf"
			;;
		esac
	} >> "$_pdir/conf/pot.conf"
	if [ -e "$_pbdir/conf/prestart.sh" ]; then
		cp "$_pbdir/conf/prestart.sh" "$_pdir/conf/prestart.sh"
	fi
	if [ -e "$_pbdir/conf/prestop.sh" ]; then
		cp "$_pbdir/conf/prestop.sh" "$_pdir/conf/prestop.sh"
	fi
	if [ -e "$_pbdir/conf/poststart.sh" ]; then
		cp "$_pbdir/conf/poststart.sh" "$_pdir/conf/poststart.sh"
	fi
	if [ -e "$_pbdir/conf/poststop.sh" ]; then
		cp "$_pbdir/conf/poststop.sh" "$_pdir/conf/poststop.sh"
	fi
}

# shellcheck disable=SC2039
pot-clone()
{
	# shellcheck disable=SC2039
	local _pname _ipaddr _potbase _pblvl _autosnap _pb_type _pb_network_type _network_type _bridge_name _network_stack
	_pname=
	_ipaddr=
	_potbase=
	_pblvl=0
	_autosnap="NO"
	_bridge_name=
	_network_stack=
	OPTIND=1
	while getopts "hvp:i:P:FN:B:S:" _o ; do
		case "$_o" in
			h)
				clone-help
				${EXIT} 0
				;;
			v)
				_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
				;;
			p)
				_pname=$OPTARG
				;;
			N)
				# shellcheck disable=SC2086
				if ! _is_in_list "$OPTARG" $_POT_NETWORK_TYPES ; then
					_error "Network type $OPTARG not recognized"
					clone-help
					${EXIT} 1
				fi
				_network_type="$OPTARG"
				;;
			i)
				if [ -z "$_ipaddr" ]; then
					_ipaddr="$OPTARG"
				else
					_ipaddr="$_ipaddr $OPTARG"
				fi
				;;
			P)
				_potbase=$OPTARG
				;;
			B)
				_bridge_name=$OPTARG
				;;
			S)
				if ! _is_in_list "$OPTARG" "ipv4" "ipv6" "dual" ; then
					_error "Network stack $OPTARG not valid"
					create-help
					${EXIT} 1
				fi
				_network_stack="$OPTARG"
				;;
			F)
				_autosnap="YES"
				;;
			*)
				clone-help
				${EXIT} 1
				;;
		esac
	done

	if [ -z "$_pname" ]; then
		_error "pot name is missing (option -p)"
		clone-help
		${EXIT} 1
	fi
	if [ -z "$_potbase" ]; then
		_error "reference pot name is missing (option -P)"
		clone-help
		${EXIT} 1
	fi
	if ! _is_pot "$_potbase" quiet ; then
		_error "reference pot $_potbase not found"
		clone-help
		${EXIT} 1
	fi
	if _is_pot "$_pname" quiet ; then
		_error "pot $_pname already exists"
		clone-help
		${EXIT} 1
	fi
	if [ -z "$_network_type" ]; then
		_pb_network_type="$( _get_pot_network_type "$_potbase" )"
		if [ -z "$_pb_network_type" ] ; then
			_error "Configuration file for $_potbase contains obsolete elements"
			_error "Please run pot update-config -p $_potbase to fix"
			${EXIT} 1
		fi
		_network_type="$_pb_network_type"
	fi
	if [ -z "$_network_stack" ]; then
		_network_stack="$( _get_pot_network_stack "$_potbase" )"
	fi
	if ! _ipaddr="$( _validate_network_param "$_network_type" "$_ipaddr" "$_bridge_name" "$_network_stack" )" ; then
		echo "$_ipaddr"
		clone-help
		${EXIT} 1
	fi
	_pblvl="$( _get_conf_var "$_potbase" pot.level )"
	_pb_type="$( _get_conf_var "$_potbase" pot.type )"
	if [ "$_pblvl" = "0" ] && [ "$_pb_type" != "single" ]; then
		_error "Level 0 pots cannot be cloned"
		clone-help
		${EXIT} 1
	fi
	if ! _is_uid0 ; then
		${EXIT} 1
	fi
	if ! _cj_zfs "$_pname" "$_potbase" $_autosnap ; then
		${EXIT} 1
	fi
	if ! _cj_conf "$_pname" "$_potbase" "$_network_type" "$_ipaddr" "$_bridge_name" "$_network_stack" ; then
		${EXIT} 1
	fi
}
