import json
E="\x1b"
W,H = 94,30
events=[]; t=0.0
def emit(s): events.append([round(t,3),"o",s])
def out(s, dt=0.03):
    global t; t+=dt; emit(s)
def typ(s, cps=18):
    global t
    for ch in s:
        t+=1.0/cps; emit(ch)
def pause(dt):
    global t; t+=dt

R=E+"[0m"
PROMPT=E+"[38;2;74;222;128m~"+R+" $ "
GRAD=['45;212;191','56;189;248','59;130;246','99;102;241','139;92;246','168;85;247']
ART=[
' █████╗ ██╗    ███╗   ███╗███████╗███╗   ███╗ ██████╗ ██████╗ ██╗   ██╗',
'██╔══██╗██║    ████╗ ████║██╔════╝████╗ ████║██╔═══██╗██╔══██╗╚██╗ ██╔╝',
'███████║██║    ██╔████╔██║█████╗  ██╔████╔██║██║   ██║██████╔╝ ╚████╔╝ ',
'██╔══██║██║    ██║╚██╔╝██║██╔══╝  ██║╚██╔╝██║██║   ██║██╔══██╗  ╚██╔╝  ',
'██║  ██║██║    ██║ ╚═╝ ██║███████╗██║ ╚═╝ ██║╚██████╔╝██║  ██║   ██║   ',
'╚═╝  ╚═╝╚═╝    ╚═╝     ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ',
]
out(PROMPT,0.4); pause(0.5)
typ("npm create ai-memory@latest"); pause(0.5); out("\r\n")
pause(0.7); out(E+"[2mnpm"+R+" "+E+"[33mwarn"+R+" exec create-ai-memory@0.1.0\r\n")
pause(0.4); out("create-ai-memory: installing into ~/ai-memory\r\n")
out("\r\n",0.2)
for i,l in enumerate(ART):
    out(E+"[1;38;2;"+GRAD[i]+"m"+l+R+"\r\n",0.12)
out(E+"[2m   persistent, agent-agnostic session memory · one vault, any CLI"+R+"\r\n",0.1)
out("\r\n")
pause(0.6); out("  Where should your memory vault live? "+E+"[2m[~/.ai-memory/_Ai_Memory]"+R+" ")
pause(1.1); out("\r\n")
pause(0.3); out("  Which agents should get <agent>-start launchers? "+E+"[2m[claude codex gemini cursor opencode]"+R+" ")
pause(1.1); out("\r\n")
out("\r\n"); pause(0.3)
out("  scaffolding vault at: ~/.ai-memory/_Ai_Memory\r\n")
for f in ["_Global_Profile.md","_Standards.md","_project_template.md","_session_template.md"]:
    pause(0.18); out("    "+E+"[32mcreate"+R+" "+f+"\r\n")
out("\r\n"); pause(0.4); out("  Append the setup lines to ~/.zshrc now? "+E+"[2m[Y/n]"+R+" ")
pause(1.0); out("\r\n")
pause(0.3); out("  "+E+"[32madded"+R+" to ~/.zshrc\r\n")
out("\r\n"); out("  Reload your shell:  "+E+"[1mexec zsh"+R+"\r\n")
out("\r\n"); pause(0.3)
out("  "+E+"[1;38;2;56;189;248mDone."+R+" From inside any git repo, run:  "+E+"[1mclaude-start"+R+"\r\n")
out("  "+E+"[2m(or codex-start / gemini-start / cursor-start / opencode-start)"+R+"\r\n")
out("\r\n"); out(PROMPT,0.2); pause(2.5)

hdr={"version":2,"width":W,"height":H,"env":{"TERM":"xterm-256color","SHELL":"/bin/zsh"}}
p="/Users/ramchristopherbaarde/create-ai-memory/assets/demo.cast"
with open(p,"w") as fp:
    fp.write(json.dumps(hdr)+"\n")
    for e in events: fp.write(json.dumps(e,ensure_ascii=False)+"\n")
print("events:",len(events),"duration:",round(t,1),"s ->",p)
