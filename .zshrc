# Auto Alias Scripts From ~/scripts
if [ -d "/mnt/me/Document/Programming/BashScripts" ]; then
  for script in "/mnt/me/Document/Programming/BashScripts"/*; do
    if [ -f "$script" ] && [ -x "$script" ]; then
      script_name=$(basename "$script")
      alias_name="${script_name%.*}"
      alias "$alias_name"="$script"
    fi
  done
fi

