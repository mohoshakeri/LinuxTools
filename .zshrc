export ZSH="$HOME/.oh-my-zsh"


ZSH_THEME="agnoster"

plugins=(git)

source $ZSH/oh-my-zsh.sh

source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh  
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

echo "Hello"

# Auto Alias Scripts From ~/scripts
if [ -d "/mnt/me/Document/Programming/LinuxTools/scripts" ]; then
  for script in "/mnt/me/Document/Programming/LinuxTools/scripts"/*; do
    if [ -f "$script" ] && [ -x "$script" ]; then
      script_name=$(basename "$script")
      alias_name="${script_name%.*}"
      alias "$alias_name"="$script"
    fi
  done
fi
