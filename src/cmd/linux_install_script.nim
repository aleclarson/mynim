## Generate the per-user Linux installer shipped alongside release archives.

import std/[json, os, strutils]
import ./update_artifacts as updateArtifacts

const installScriptTemplate = """#!/bin/sh
# Installs @@TITLE@@ for the current user, without root: the app in
# ~/.local/@@SLUG@@.app@@COMMAND_COMMENT@@ and its entry in the applications menu.
# Made by nim-xplat build.
@@CURL_COMMENT@@#   sh install.sh [ARCHIVE]
#   sh install.sh --uninstall
set -eu

app_name=@@APP_NAME@@
name=@@SLUG@@
# The command in ~/.local/bin that runs the app (linux.command), if any.
command_name=@@COMMAND@@
version=@@VERSION@@
# Where the manifests of the latest version are, with updates: in the
# release of the newest tag with the prefix when the repository's releases
# (api) hold others too.
releases=@@RELEASES@@
api=@@API@@
tag_prefix=@@TAG_PREFIX@@

usage() {
	cat <<EOF
Usage: sh install.sh [ARCHIVE | --uninstall]

Installs $app_name for you in ~/.local: ARCHIVE, else
$name-$version-<platform>.tar.gz next to this script@@LATEST_HINT@@. --uninstall removes it, and leaves its settings
and data in place.
EOF
}

fail() {
	echo "install.sh: $*" >&2
	exit 1
}

fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1"
	else
		wget -qO- "$1"
	fi
}

main() {
	app_dir="$HOME/.local/$name.app"
	bin_dir="$HOME/.local/bin"
	data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
	desktop_file="$data_home/applications/$name.desktop"
	mime_file="$data_home/mime/packages/$name.xml"

	if [ $# -gt 1 ]; then
		usage >&2
		exit 2
	fi
	case "${1:-}" in
	-h | --help)
		usage
		return
		;;
	--uninstall)
		uninstall
		return
		;;
	-*)
		usage >&2
		exit 2
		;;
	esac

	[ "$(uname -s)" = Linux ] || fail "$app_name installs on Linux"
	[ "$(id -u)" != 0 ] || fail "run this as the user to install $app_name for, not as root"
	# The desktop entry holds the path, which these characters would break.
	[ "$(printf '%s' "$app_dir" | tr -d '"$%\\\140\n')" = "$app_dir" ] ||
		fail "cannot install in $app_dir: the path has characters a desktop entry cannot hold"
	case "$(uname -m)" in
	x86_64 | amd64) target=linux-amd64 ;;
	aarch64 | arm64) target=linux-arm64 ;;
	*) fail "$app_name is not made for $(uname -m)" ;;
	esac

	work="$(mktemp -d)"
	staging="$HOME/.local/.$name.app.install"
	trap 'rm -rf "$work" "$staging"' EXIT
	trap 'exit 1' HUP INT TERM

	archive="${1:-}"
	if [ -z "$archive" ] && [ -f "$0" ] && [ -f "$(dirname -- "$0")/$name-$version-$target.tar.gz" ]; then
		archive="$(dirname -- "$0")/$name-$version-$target.tar.gz"
	fi
	if [ -z "$archive" ]; then
		[ -n "$releases" ] || fail "no $name-$version-$target.tar.gz next to this script: pass the archive to install"
		command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || fail "downloading $app_name needs curl or wget"
		if [ -n "$api" ]; then
			tag="$(latest_tag)" || fail "could not list the releases at $api"
			[ -n "$tag" ] || fail "no release of $app_name is published"
			manifest="$releases$tag/update-$target.json"
		else
			manifest="${releases}update-$target.json"
		fi
		fetch "$manifest" >"$work/update.json" || fail "could not download $manifest"
		latest="$(sed -n 's/^  "version": \"\(.*\)\",$/\1/p' "$work/update.json")"
		url="$(sed -n 's/^  "url": \"\(.*\)",$/\1/p' "$work/update.json")"
		[ -n "$url" ] || fail "$manifest names no archive"
		echo "Downloading $app_name $latest"
		archive="$work/$name.tar.gz"
		fetch "$url" >"$archive" || fail "could not download $url"
	fi
	[ -f "$archive" ] || fail "no archive at $archive"
	tar -tzf "$archive" >"$work/names" 2>/dev/null || fail "$archive is not a .tar.gz archive"
	if grep -Eq '^/|(^|/)\.\.(/|$)' "$work/names"; then
		fail "$archive holds files outside the app"
	fi

	echo "Installing $app_name in $app_dir"
	rm -rf "$staging"
	mkdir -p "$staging"
	tar -xzf "$archive" -C "$staging"
	[ -f "$staging/$name" ] && [ -x "$staging/$name" ] || fail "$archive is not $app_name: it holds no $name"
	# Replace the app as a whole, so that no file of another version stays.
	rm -rf "$app_dir"
	mv "$staging" "$app_dir"

	mkdir -p "$data_home/applications"
	# Earlier install scripts linked a command named after the app.
	if [ "$name" != "$command_name" ] && ours "$bin_dir/$name"; then
		rm -f "$bin_dir/$name"
	fi
	run=
	if [ -n "$command_name" ]; then
		bin_link="$bin_dir/$command_name"
		if { [ -e "$bin_link" ] || [ -L "$bin_link" ]; } && ! ours "$bin_link"; then
			echo "Leaving $bin_link alone: it is not $app_name's" >&2
		else
			mkdir -p "$bin_dir"
			ln -sf "$app_dir/$name" "$bin_link"
			if [ "$(command -v "$command_name" || true)" = "$bin_link" ]; then
				run=$command_name
			else
				run=$bin_link
			fi
		fi
	fi
	# The entry runs the app and shows its icon by their paths. Updates
	# register the desktop entry the same way.
	if [ -f "$app_dir/$name.desktop" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
			"Exec=$name" | "Exec=$name "*) line="Exec=\"$app_dir/$name\"${line#"Exec=$name"}" ;;
			"Icon=$name") if [ -f "$app_dir/$name.png" ]; then line="Icon=$app_dir/$name.png"; fi ;;
			esac
			printf '%s\n' "$line"
		done <"$app_dir/$name.desktop" >"$desktop_file"
	fi
	if [ -f "$app_dir/$name.xml" ]; then
		mkdir -p "$data_home/mime/packages"
		cp "$app_dir/$name.xml" "$mime_file"
	else
		rm -f "$mime_file"
	fi
	update_databases

	if [ -n "$run" ]; then
		echo "Installed $app_name: open it from the applications menu, or run $run"
	else
		echo "Installed $app_name: open it from the applications menu"
	fi
	if ! has_webkit; then
		echo "$app_name needs WebKitGTK, which is not installed. Install it with:" >&2
		echo "  $(webkit_install_command)" >&2
	fi
}

# latest_tag prints the tag of the newest release tagged $tag_prefix that is
# neither a draft nor a prerelease.
latest_tag() {
	page=1
	while [ "$page" -le 10 ]; do
		fetch "$api&page=$page" >"$work/releases.json" || return 1
		tr -d '\n' <"$work/releases.json" |
			grep -oE '"(tag_name|draft|prerelease)": *("[^"]*"|true|false)' >"$work/fields" || true
		tag="$(awk -v prefix="$tag_prefix" '
			/^"tag_name"/ { sub(/^"tag_name": *"/, ""); sub(/"$/, ""); tag = $0; draft = 0; next }
			/^"draft"/ { draft = /true$/; next }
			/^"prerelease"/ { if (!draft && /false$/ && index(tag, prefix) == 1) { print tag; exit } }
		' "$work/fields")"
		if [ -n "$tag" ]; then
			echo "$tag"
			return
		fi
		# A full page leads to the next.
		[ "$(grep -c '^"tag_name"' "$work/fields" || true)" -ge 100 ] || return 0
		page=$((page + 1))
	done
}

# has_webkit succeeds when the cache cannot establish whether WebKitGTK is
# present, such as on NixOS or musl systems.
has_webkit() {
	for ldconfig in "$(command -v ldconfig || true)" /sbin/ldconfig /usr/sbin/ldconfig; do
		[ -n "$ldconfig" ] && [ -x "$ldconfig" ] || continue
		"$ldconfig" -p >"$work/libs" 2>/dev/null || return 0
		grep -qF libc.so.6 "$work/libs" || return 0
		grep -qF -e libwebkit2gtk-4.1.so.0 -e libwebkit2gtk-4.0.so.37 "$work/libs"
		return
	done
	return 0
}

webkit_install_command() {
	distro=
	for file in /etc/os-release /usr/lib/os-release; do
		if [ -f "$file" ]; then
			distro="$(. "$file" && echo "${ID:-} ${ID_LIKE:-}")" || true
			break
		fi
	done
	for id in $distro; do
		case "$id" in
		debian | ubuntu) echo "sudo apt install libwebkit2gtk-4.1-0" && return ;;
		fedora) echo "sudo dnf install webkit2gtk4.1" && return ;;
		arch) echo "sudo pacman -S webkit2gtk-4.1" && return ;;
		opensuse* | suse) echo "sudo zypper install libwebkit2gtk-4_1-0" && return ;;
		esac
	done
	echo "the package manager of your system (the library is libwebkit2gtk-4.1.so.0)"
}

uninstall() {
	[ -d "$app_dir" ] || fail "$app_name is not installed in $app_dir"
	# Only what install.sh and the app made; a system package may use the same names.
	for link in "$bin_dir/$name" "$bin_dir/$command_name"; do
		if ours "$link"; then
			rm -f "$link"
		fi
	done
	if [ -f "$desktop_file" ] && grep -qF "$app_dir/" "$desktop_file"; then
		rm -f "$desktop_file" "$mime_file"
	fi
	for entry in "$data_home"/applications/*.url-handler.desktop; do
		if [ -f "$entry" ] && grep -qF "$app_dir/" "$entry"; then
			rm -f "$entry"
		fi
	done
	rm -rf "$app_dir"
	update_databases
	echo "Uninstalled $app_name. Its settings and data are still in place."
}

# ours tells whether $1 is the link to the app that install.sh makes.
ours() {
	[ -L "$1" ] && [ "$(readlink "$1")" = "$app_dir/$name" ]
}

update_databases() {
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true
	fi
	if [ -d "$data_home/mime/packages" ] && command -v update-mime-database >/dev/null 2>&1; then
		update-mime-database "$data_home/mime" >/dev/null 2>&1 || true
	fi
}

main "$@"
"""

proc configString(node: JsonNode; key, path, fallback: string): string =
  if node.kind != JObject or not node.hasKey(key):
    return fallback
  if node[key].kind != JString:
    raise newException(ValueError, "mygo.json: " & path & " must be a string")
  node[key].getStr()

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc linuxSlug(value: string): string =
  var separator = false
  for ch in value.toLowerAscii:
    if ch in {'a'..'z', '0'..'9'}:
      if separator and result.len > 0:
        result.add '-'
      result.add ch
      separator = false
    else:
      separator = true
  if result.len == 0:
    result = "app"

proc escapePathSegment(value: string): string =
  const digits = "0123456789ABCDEF"
  for ch in value:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~'}:
      result.add ch
    else:
      result.add '%'
      result.add digits[ord(ch) shr 4]
      result.add digits[ord(ch) and 0x0f]

proc installScript*(config: JsonNode; appName, version, arch: string): string =
  let slug = linuxSlug(appName)
  var command = ""
  if config.kind == JObject and config.hasKey("linux") and
      config["linux"].kind != JNull:
    if config["linux"].kind != JObject:
      raise newException(ValueError, "mygo.json: linux must be an object")
    command = configString(config["linux"], "command", "linux.command", "")

  var releases, api, prefix, curlHint, latestHint = ""
  if config.kind == JObject and config.hasKey("updates") and
      config["updates"].kind != JNull:
    discard updateArtifacts.runtimeUpdateSettings(config, "linux-" & arch)
    let updates = config["updates"]
    let github = configString(updates, "github", "updates.github", "")
    let baseUrl = configString(updates, "url", "updates.url", "")
    if github.len > 0:
      prefix = configString(updates, "tagPrefix", "updates.tagPrefix", "v")
      if prefix.len == 0:
        prefix = "v"
      if prefix == "v":
        releases = "https://github.com/" & github & "/releases/latest/download/"
      else:
        releases = "https://github.com/" & github & "/releases/download/"
        api = "https://api.github.com/repos/" & github & "/releases?per_page=100"
      curlHint = "#   curl -fsSL " & releases & "install.sh | sh\n"
      if prefix != "v":
        curlHint = "#   curl -fsSL https://github.com/" & github &
          "/releases/download/" & escapePathSegment(prefix & version) &
          "/install.sh | sh\n"
      latestHint = ", else the latest version, which it downloads"
    else:
      releases = baseUrl.strip(chars = {'/'}) & "/"
      curlHint = "#   curl -fsSL " & releases & "install.sh | sh\n"
      latestHint = ", else the latest version, which it downloads"

  var body = installScriptTemplate
  let commandComment = if command.len > 0:
    ", the " & command & " command in ~/.local/bin,"
    else: ""
  let title = appName.splitWhitespace().join(" ")
  let replacements = [
    ("@@TITLE@@", title),
    ("@@SLUG@@", slug),
    ("@@COMMAND_COMMENT@@", commandComment),
    ("@@CURL_COMMENT@@", curlHint),
    ("@@APP_NAME@@", appName),
    ("@@COMMAND@@", command),
    ("@@VERSION@@", version),
    ("@@RELEASES@@", releases),
    ("@@API@@", api),
    ("@@TAG_PREFIX@@", prefix),
    ("@@LATEST_HINT@@", latestHint)]
  for (marker, value) in replacements:
    let quoted = if marker in ["@@CURL_COMMENT@@", "@@COMMAND_COMMENT@@",
        "@@LATEST_HINT@@"]: value else: shellQuote(value)
    body = body.replace(marker, quoted)
  body

proc writeInstallScript*(stage: string; config: JsonNode;
    appName, version, arch: string): string =
  let path = stage / "install.sh"
  if fileExists(path) or dirExists(path):
    raise newException(ValueError,
      "Linux installer conflicts with staged resource install.sh")
  writeFile(path, installScript(config, appName, version, arch))
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
    fpGroupExec, fpOthersRead, fpOthersExec})
  path
