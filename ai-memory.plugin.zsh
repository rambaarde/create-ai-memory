# Entry point for zsh plugin managers (zinit, antidote, oh-my-zsh, antigen),
# which load a repo by sourcing a root-level *.plugin.zsh. It just sources the
# real module, resolved relative to this file so it works wherever the manager
# clones the repo.
source "${0:A:h}/shell/ai-mem.zsh"
