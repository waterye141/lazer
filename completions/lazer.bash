_lazer() {
  local cur prev
  _init_completion || return

  local options='--help --stats --analyze --service --source --file --unit --since --until'
  local sources='nginx apache ssh systemd_journal haproxy docker generic'

  case "$prev" in
  --source)
    mapfile -t COMPREPLY < <(compgen -W "$sources" -- "$cur")
    return
    ;;
  --file)
    _filedir
    return
    ;;
  --since|--until)
    mapfile -t COMPREPLY < <(compgen -W 'today yesterday now' -- "$cur")
    return
    ;;
  --unit)
    return
    ;;
  esac

  if [[ "$cur" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
  fi
}

complete -F _lazer lazer lazer.sh
