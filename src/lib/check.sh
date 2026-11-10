#!/bin/bash

# check.sh: Check for available updates
# https://github.com/Antiz96/arch-update
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck disable=SC2154
if [ "${2}" == "--enable" ]; then
	systemctl --user enable --now "${name}.timer"
	info_msg "$(eval_gettext "Automated update checks have been enabled")"
	exit 0
fi

# shellcheck disable=SC2154
touch "${statedir}"/last_updates_check_{packages,aur,flatpak}

# shellcheck disable=SC2154
checkupdates_db_tmpdir=$(mktemp -d "${checkupdates_db_tmpdir_prefix}XXXXX")

update_check_failed=""

# shellcheck disable=SC2154
packages=$(CHECKUPDATES_DB="${checkupdates_db_tmpdir}" timeout "${update_check_timeout}" checkupdates)
packages_exit_code=$?

if [ "${packages_exit_code}" -eq 124 ]; then
	# Keep the previous state file content to avoid falsely reporting being up to date
	warning_msg "$(eval_gettext "Unable to retrieve Packages updates (request timeout)\n")"
	update_check_failed="true"
elif [ -n "${no_version}" ]; then
	# shellcheck disable=SC2154
	echo "${packages}" | awk '{print $1}' > "${statedir}/last_updates_check_packages"
else
	# shellcheck disable=SC2154
	echo "${packages}" > "${statedir}/last_updates_check_packages"
fi

if [ -n "${aur_helper}" ]; then
	# "< /dev/null" and "2 > /dev/null" needed for pikaur (which is not completely script friendly and outputs some descriptive string in stderr when looking for updates with -Qua)
	# The former because it assumes an interactive TTY environment (causing `timeout` to behave unexpectedly)
	# shellcheck disable=SC2154
	unformatted_aur_packages=$(LC_ALL=C timeout "${update_check_timeout}" "${aur_helper}" -Qua < /dev/null 2> /dev/null)
	unformatted_aur_packages_exit_code=$?

	if [ "${unformatted_aur_packages_exit_code}" -eq 124 ]; then
		# Keep the previous state file content to avoid falsely reporting being up to date
		warning_msg "$(eval_gettext "Unable to retrieve AUR Packages updates (request timeout)\n")"
		update_check_failed="true"
	elif [ -n "${no_version}" ]; then
		echo "${unformatted_aur_packages}" | sed 's/^ *//' | sed 's/ \+/ /g' | grep -vw "\[ignored\]$" | awk '{print $1}' > "${statedir}/last_updates_check_aur"
	else
		echo "${unformatted_aur_packages}" | sed 's/^ *//' | sed 's/ \+/ /g' | grep -vw "\[ignored\]$" > "${statedir}/last_updates_check_aur"
	fi
fi

if [ -n "${flatpak_support}" ]; then
	# shellcheck disable=SC2154
	timeout --foreground "${update_check_timeout}" flatpak update --appstream > /dev/null
	flatpak_metadata_update_exit_code=$?

	if [ "${flatpak_metadata_update_exit_code}" -eq 124 ]; then
		# Keep the previous state file content to avoid falsely reporting being up to date
		warning_msg "$(eval_gettext "Unable to retrieve Flatpak packages updates (request timeout)\n")"
		update_check_failed="true"
	else
		mapfile -t flatpak_mask < <(flatpak mask | tr -d ' ')

		if [ "${#flatpak_mask[@]}" -gt 0 ]; then
			mapfile -t flatpak_packages < <(flatpak remote-ls --updates --columns=application,version | tr -s '\t' ' ')

			declare -A app_names
			while read -r flatpak_id flatpak_name; do
				app_names["${flatpak_id}"]="${flatpak_name}"
			done < <(flatpak list --columns=application,name)

		        mapfile -t flatpak_packages < <(
				for packages in "${flatpak_packages[@]}"; do
					read -r app_id app_version <<< "${packages}"

					for pattern in "${flatpak_mask[@]}"; do
						# shellcheck disable=SC2053
						[[ "${app_id}" == ${pattern} ]] && continue 2
					done

					app_name="${app_names[${app_id}]:-${app_id}}"

					if [ -z "${no_version}" ]; then
						echo "${app_name} ${app_version}"
					else
						echo "${app_name}"
					fi
				done
			)
		else
			if [ -z "${no_version}" ]; then
				mapfile -t flatpak_packages < <(flatpak remote-ls --updates --columns=name,version | tr -s '\t' ' ')
			else
				mapfile -t flatpak_packages < <(flatpak remote-ls --updates --columns=name)
			fi
		fi

		printf "%s\n" "${flatpak_packages[@]}" > "${statedir}/last_updates_check_flatpak"
	fi
fi

sed -i '/^\s*$/d' "${statedir}"/last_updates_check_{packages,aur,flatpak}
sed -ri 's/\x1B\[[0-9;]*m//g' "${statedir}"/last_updates_check_{packages,aur,flatpak}
update_available=$(cat "${statedir}"/last_updates_check_{packages,aur,flatpak})

# shellcheck disable=SC2154
echo "${update_available}" > "${statedir}/current_updates_check"

if [ -n "${update_available}" ] && [ -n "${notification_support}" ] && ! diff "${statedir}/current_updates_check" "${statedir}/last_updates_check" &> /dev/null; then
	update_number=$(wc -l "${statedir}/current_updates_check" | awk '{print $1}')

	# shellcheck disable=SC2154
	last_notif_id=$(sed -n '1p' "${tmpdir}/notif_param" 2> /dev/null)

	systemctl --user stop "${name}-notification.service" 2>/dev/null || true

	systemd-run --user --unit="${name}-notification" --quiet \
		--setenv=DISPLAY="${DISPLAY}" \
		--setenv=DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
		--setenv=TEXTDOMAIN="${_name}" \
		--setenv=TEXTDOMAINDIR="${TEXTDOMAINDIR}" \
		--setenv=LANG="${LANG}" \
		--setenv=LANGUAGE="${LANGUAGE}" \
		--setenv=LC_ALL="${LC_ALL}" \
		--setenv=LC_MESSAGES="${LC_MESSAGES}" \
		--setenv=XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
		--setenv=XDG_DATA_HOME="${XDG_DATA_HOME}" \
		--setenv=XDG_DATA_DIRS="${XDG_DATA_DIRS}" \
		--setenv=HOME="${HOME}" \
		--setenv=update_number="${update_number}" \
		--setenv=last_notif_id="${last_notif_id}" \
		--setenv=_name="${_name}" \
		--setenv=name="${name}" \
		--setenv=tray_icon_style="${tray_icon_style}" \
		--setenv=colorblind_mode="${colorblind_mode}" \
		--setenv=tmpdir="${tmpdir}" \
		--setenv=desktop_file="${desktop_file}" \
	"${libdir}/notification.sh"
fi

if [ -f "${statedir}/current_updates_check" ]; then
	mv -f "${statedir}/current_updates_check" "${statedir}/last_updates_check"
fi

if [ -n "${update_available}" ]; then
	icon_updates-available
elif [ -z "${update_check_failed}" ]; then
	icon_up-to-date
fi

date "+%s%n%F %T" > "${statedir}/last_updates_check_time"
