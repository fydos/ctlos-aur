#!/bin/bash
# Fork https://github.com/alexheretic/aurto

# rsync -cauv --delete --info=stats2 --exclude={"aurdb.sh.files","*.files.tar*","aurdb.sh.db","*.db.tar*"} /var/cache/pacman/aurdb.sh/ /home/cretm/app/dev.ctlos.ru/ctlos-aur

# find './' -maxdepth 1 -type f -regex '.*\.\(zst\|xz\)' -exec gpg -b '{}' \;
# find './' -type f -exec gpg --pinentry-mode loopback --passphrase=${GPG_PASS} -b '{}' \;

### disable gpg sign
# rm (--sign)
# rm repo-(add,remove) -v -s
## add /etc/pacman.conf
# SigLevel = Optional TrustAll

command=${1:-}
arg1=${2:-}

src_dir=/home/cretm/ctlos-aur
repo_dir="$src_dir"/repo
repo_name=ctlos-aur
makepkg_conf="$src_dir"/conf/makepkg.conf
pacman_conf="$src_dir"/conf/pacman.conf

## disable chroot
export chroot_arg='--chroot'
# if test -f "$src_dir"/disable-chroot; then
  # export chroot_arg=''
# fi

if test -t 1; then
  function green { echo -e "\\e[32m$*\\e[39m"; }
  function cyan { echo -e "\\e[36m$*\\e[39m"; }
  function red { echo -e "\\e[31m$*\\e[39m"; }
  function yellow { echo -e "\\e[33m$*\\e[39m"; }
  function dim { echo -e "\\e[2m$*\\e[22m"; }
fi

if [ "$command" == "init" ]; then
  repo-add "$repo_dir"/"$repo_name".db.tar.gz

  echo 'Adding & enabling systemd timer' >&2
  service_dir=$HOME/.config/systemd/user
  [ ! -d $service_dir ] && mkdir -p $service_dir
  cp -r "$src_dir"/service/* "$service_dir"
  systemctl --user enable --now check-aur-git-trigger.timer
  systemctl --user enable --now upgrade-aur.timer
  systemctl --user enable upgrade-aur-startup.timer

elif [ "$command" == "conf" ]; then
  if [[ $EUID -ne 0 ]]; then
    echo "run:    sudo aurdb.sh conf"
    exit 1
  fi
  echo
  if test -t 1; then
    read -p "Add [$repo_name] \>\> /etc/pacman.conf \? [yN] " -n1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo -e "\\n["$repo_name"]\\nSigLevel = Optional TrustAll\\nServer = file://$repo_dir" >> /etc/pacman.conf
    fi
  fi
  echo
  if test -t 1; then
    read -p "Add $SUDO_USER ALL=\(ALL\) NOPASSWD \>\> /etc/sudoers \? [yN] " -n1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo -e "\\n$SUDO_USER ALL=(ALL) NOPASSWD:SETENV: /usr/bin/makechrootpkg" >> /etc/sudoers
      echo -e "$SUDO_USER ALL=(ALL) NOPASSWD: /usr/bin/arch-nspawn" >> /etc/sudoers
      echo -e "$SUDO_USER ALL=(ALL) NOPASSWD: /usr/bin/pacsync $repo_name" >> /etc/sudoers
      echo -e "$SUDO_USER ALL=(ALL) NOPASSWD: /usr/bin/aur" >> /etc/sudoers
    fi
  fi

elif [ "$command" == "add" ] && [ -n "$arg1" ]; then
  packages_and_deps="${*:2}"
  for i in "${@:2}"; do
    packages_and_deps="$packages_and_deps
  $(echo "$i" | aur depends 2>/dev/null | cut -f2 | sort | comm -12 - <(aur pkglist | sort))"
  done
  sudo pacsync $repo_name >/dev/null;

  echo "Running: aur sync --no-view --no-confirm ${chroot_arg:---no-ver} --database=$repo_name --makepkg-conf=${makepkg_conf} --pacman-conf=${pacman_conf} ${*:2}" >&2
  aur sync --no-view --no-confirm "${chroot_arg:---no-ver}" \
    --database="$repo_name" \
    --makepkg-conf="${makepkg_conf}" \
    --pacman-conf="${pacman_conf}" "${@:2}"
  sudo pacsync $repo_name >/dev/null;
  echo -e "aurdb.sh: To install run: sudo pacman -Syy "${*:2}"" >&2

elif [ "$command" == "addpkg" ] && [ -n "$arg1" ]; then
  repo-add -n -R "$repo_dir"/"$repo_name".db.tar.gz "${@:2}"
  for pkg in "${@:2}"*; do
    cp "$pkg" "$repo_dir"/
  done
  sudo pacsync $repo_name >/dev/null;
  echo -e "aurdb.sh: To install run: sudo pacman -Syy PACKAGES..." >&2

elif [ "$command" == "remove" ] && [ -n "$arg1" ]; then
  removed=""
  for pkg in "${@:2}"; do
    if remove_out=$(repo-remove "$repo_dir"/"$repo_name".db.tar.gz "$pkg" 2>&1); then
      if [[ $remove_out = *"ERROR"* ]]; then
        echo "aurdb.sh: $pkg not found" >&2
      else
        rm -rf "$repo_dir"/"$pkg"*.pkg.* || true
        removed="$pkg $removed"
      fi
    else
      echo "aurdb.sh: "$pkg" not found" >&2
      rm -rf "$repo_dir"/"$pkg"*.pkg.* || true
    fi
  done
  if [ -n "$removed" ]; then
    echo -e "Removed $removed" >&2
    sudo pacsync $repo_name >/dev/null;
  fi

elif [ "$command" == "upgrade" ]; then
  ## Clean aurutils cache
  clean_aurutils_cache() {
    aurutils_cache=$HOME/.cache/aurutils/sync/
    if [ -d "$aurutils_cache" ]; then
      rm -rf "$aurutils_cache"
    fi
  }
  trap clean_aurutils_cache EXIT
  sudo pacsync $repo_name >/dev/null;

  echo "Running: aur sync --no-view --no-confirm $chroot_arg --database=$repo_name --makepkg-conf=${makepkg_conf} --pacman-conf=${pacman_conf} --upgrades" >&2
  aur sync --no-view --no-confirm "$chroot_arg" \
    --database="$repo_name" \
    --makepkg-conf="${makepkg_conf}" \
    --pacman-conf="${pacman_conf}" \
    --upgrades

  readonly AURVCS=${AURVCS:-.*-(cvs|svn|git|hg|bzr|darcs)$}

  if rm "/tmp/check-vcs" 2>/dev/null; then
    vcs_pkgs=$(aur repo --database="$repo_name" --list | cut -f1 | grep -E "$AURVCS" || true)
    if [ -n "$vcs_pkgs" ]; then
      echo "Checking $(echo "$vcs_pkgs" | wc -l) VCS packages matching "$AURVCS" for updates..." >&2
      # init vcs sync cache (aurutils v3 args with ||-fallback to v2 args)
      aur sync "$vcs_pkgs" \
        --no-ver-argv --no-view --no-build --database="$repo_name" >/dev/null 2>&1 \
      || aur sync "$vcs_pkgs" \
        --no-ver-shallow --print --database="$repo_name" >/dev/null 2>&1

      mapfile -t git_outdated < <("$src_dir"/aur-vercmp-devel --database="$repo_name" | cut -d: -f1)
      if [ ${#git_outdated[@]} -gt 0 ]; then
        repo-remove "$repo_dir"/"$repo_name".db.tar.gz "${git_outdated[@]}"
        for i in ${git_outdated[@]}; do
          rm -rf "$repo_dir"/${i}*.pkg.*
          # repo-add -n -R "$repo_dir"/"$repo_name".db.tar.gz "$repo_dir"/${i}*.pkg.*
        done
        aur sync --no-view --no-confirm "${chroot_arg:---no-ver}" \
          --database="$repo_name" \
          --makepkg-conf="${makepkg_conf}" \
          --pacman-conf="${pacman_conf}" "${git_outdated[@]}"
        sudo pacsync $repo_name >/dev/null;
        echo ${git_outdated[@]}
      else
        echo " VCS packages up to date ✓" >&2
      fi
    fi
  fi
  echo " aurdb.sh: upgrade Repo Done!" >&2
  sudo pacsync $repo_name >/dev/null;
  paccache -rk1 -c "$repo_dir"

elif [ "$command" == "list" ]; then
  aur repo --database="$repo_name" --list

elif [ "$command" == "uninstall" ]; then
  echo "aurdb.sh: disable systemd timer" >&2
  systemctl --user disable --now check-aur-git-trigger.timer || true
  systemctl --user disable --now upgrade-aur.timer || true
  systemctl --user disable --now upgrade-aur-startup.timer || true
  systemctl --user disable upgrade-aur.service || true

  echo "aurdb.sh: Clean $repo_dir" >&2
  rm -rf $repo_dir/* 2>/dev/null || true

  echo "aurdb.sh: Removing $repo_name /etc/pacman.conf" >&2
  sudo sed -i "/\[$repo_name\]/,+2d" /etc/pacman.conf

  echo "aurdb.sh: Removing ${SUDO_USER:-$USER} ALL = NOPASSWD /etc/sudoers" >&2
  sudo sed -i "/makechrootpkg/,+3d" /etc/sudoers

elif [ "$command" == "status" ]; then
  echo_status() {
    echo "$repo_name $(cyan "$(pacman -Sql $repo_name | wc -l)") packages: $(cyan pacman -Sl $repo_name)"
    echo
    pacman -Sl $repo_name --color=always | sed 's/^/  /'
    echo
    echo "Timers: $(cyan systemctl --user list-timers)"
    list_timers=$(systemctl --user list-timers -a)
    echo "  $(echo "$list_timers" | head -n1 | cut -c1-"$COLUMNS")"
    echo "$list_timers" \
     | grep -E 'aur' \
     | sed 's/^/  /' \
     | cut -c1-"$COLUMNS"
    echo
    echo "Recent logs: $(cyan journalctl --user -eu upgrade-aur --since \'1.5 hours ago\')"
    journalctl --user -eu upgrade-aur --since '1.5 hours ago' \
     | sed 's/^/  /' \
     | cut -c1-"$COLUMNS"
    echo
    echo "Log warnings: $(cyan journalctl --user -eu upgrade-aur --since \'1 week ago\' \| grep -v \'Skipping all source file integrity\' \|  grep -E \'ERROR\|WARNING\' -A5 -B5)"
    log_warns=$(
      journalctl --user -eu upgrade-aur --since '1 week ago' \
       | grep -v 'Skipping all source file integrity' \
       | grep -E 'ERROR|WARNING' -A5 -B5 --color=always \
       | sed 's/^/  /'
    )
    if [ -n "$log_warns" ]; then
      echo "$log_warns" | cut -c1-"$COLUMNS"
    else
      green '  None'
    fi
  }
  sudo pacsync $repo_name >/dev/null;
  echo_status | less -RF

else
  echo "tool repository"
  echo "  General usage: $(green aurdb.sh add)|$(green addpkg)|$(green remove) $(cyan PACKAGES...)"
  echo
  echo "  Examples"
  echo "  - init: Init repo & systemd (services,timer)"
  echo "      $(green aurdb.sh) $(cyan init)"
  echo
  echo "  - conf: Mod /etc/pacman.conf & /etc/sudoers"
  echo "      $(red sudo) $(green aurdb.sh) $(cyan conf)"
  echo
  echo "  - add: build aur packages & dependencies, add repo"
  echo "      $(green aurdb.sh add) $(cyan aurutils)"
  echo
  echo "  - remove: remove packages repo"
  echo "      $(green aurdb.sh remove) $(cyan aurutils)"
  echo
  echo "  - addpkg: add package repo"
  echo "      $(green aurdb.sh addpkg) $(cyan /path/to/aurutils-2.3.1-1-any.pkg.tar.zst)"
  echo
  echo "  - upgrade: upgrade aur repo"
  echo "      $(green aurdb.sh) $(cyan upgrade)"
  echo
  echo "  - list: list aur repo pkg"
  echo "      $(green aurdb.sh) $(cyan list)"
  echo
  echo "  - status: status repo"
  echo "      $(green aurdb.sh) $(cyan status)"
  echo
  echo "  - uninstall: uninstall repo"
  echo "      $(green aurdb.sh) $(cyan uninstall)"
  echo
  exit 1
fi
