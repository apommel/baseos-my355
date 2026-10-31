# baseos.conf, read with builtins: KEY=VALUE lines and # comments, CRLF
# tolerated. Card contents are data, never shell code.

# Linked by rcS; none means the defaults.
BASEOS_CONF=/run/baseos.conf

# conf_get KEY [FILE]: sets $CONF_VALUE to the last KEY's value, trimmed, or
# empty. ssh_password keeps a #, which elsewhere starts a comment.
conf_get() {
	CONF_VALUE=
	[ -f "${2:-$BASEOS_CONF}" ] && [ -r "${2:-$BASEOS_CONF}" ] || return 0
	while IFS= read -r _l || [ -n "$_l" ]; do
		_l=${_l#"${_l%%[![:space:]]*}"}
		case "$_l" in \#*) continue ;; *=*) ;; *) continue ;; esac
		_k=${_l%%=*} _v=${_l#*=}
		_k=${_k%"${_k##*[![:space:]]}"}
		[ "$_k" = "$1" ] || continue
		[ "$1" = ssh_password ] || _v=${_v%%#*}
		_v=${_v#"${_v%%[![:space:]]*}"} _v=${_v%"${_v##*[![:space:]]}"}
		CONF_VALUE=$_v
	done < "${2:-$BASEOS_CONF}"
}
