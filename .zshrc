export ZSH="$HOME/.oh-my-zsh"


ZSH_THEME="agnoster"

plugins=(git)

source $ZSH/oh-my-zsh.sh

source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh  
source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

echo "Hello"

# PyEnv
export PATH="$HOME/.pyenv/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

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

