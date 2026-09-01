# docker-dev-sandbox

A reusable Docker sandbox for Node projects on Windows, so you can let AI agents
run wild inside a project without giving it access to your whole machine.

The image holds **no project code**. Your project is bind-mounted in at run time, so
one image serves every repo you own. From any project folder:

```powershell
cd C:\Users\[user]\Documents\GitHub\some-project
dev-sandbox
```

…and you land in a container shell at `/workspace`, with `claude` and `node` on the
PATH, read/write access to that project and nothing above it, and its dev server
reachable from your normal Windows browser.

---

## One-time setup

### 1. Build the image

```powershell
cd C:\Users\[user]\Documents\GitHub\docker-dev-sandbox
.\dev-sandbox.ps1 -Rebuild -Command "node --version"
```

The wrapper builds automatically whenever the image is missing or the `Dockerfile`
has changed since the image was built, so you rarely need `-Rebuild` by hand.

Current image: `dev-sandbox:node24`, ~809 MB, Node v24.20.0 ("Krypton", the Active
LTS line), Claude Code 2.1.252.

### 2. Add the `dev-sandbox` function to your PowerShell profile

So the command works from any folder:

```powershell
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }
notepad $PROFILE
```

Add:

```powershell
function dev-sandbox {
    & "C:\Users\[user]\Documents\GitHub\docker-dev-sandbox\dev-sandbox.ps1" @args
}
```

Then reload with `. $PROFILE`. If PowerShell blocks the script, allow local scripts
once: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 3. Authenticate once, for every project

Do this and you never log in inside a sandbox again. Pick whichever fits your plan.

**On a Claude subscription — `-ClaudeAuth`:**

```powershell
dev-sandbox -ClaudeAuth
```

This runs Claude Code's long-lived token flow: approve in the browser, then paste
back what it prints. You can paste the whole block — surrounding prose, the wrapped
token, blank lines and all — and press Enter on an empty line; the wrapper finds the
`sk-ant-oat…` token in it and reassembles it, ignoring the spaces and line breaks the
terminal added. It is then saved to your Windows user environment as
`CLAUDE_CODE_OAUTH_TOKEN`. Open a new PowerShell window afterwards.

**On API billing — set the key yourself:**

```powershell
[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", "sk-ant-...", "User")
```

Either way the wrapper forwards the value into the container as an environment
variable at creation time. It is **never written to disk** — not into the project,
not into a volume — so there is nothing to accidentally commit, and Claude Code
works immediately in every project with no per-repo login. `CLAUDE_CODE_OAUTH_TOKEN`
wins if both are set. The banner's `home` line tells you which one is in play.

Containers already running were created with the old environment, so refresh them
with `dev-sandbox -Stop` on your next visit to that project.

If you set neither, Claude Code falls back to its interactive login: run `claude`,
paste the printed URL into your Windows browser, approve, paste the code back. Those
credentials land in the project's home volume, **so you log in again for every new
project** — that is the per-project home volume working as designed
(see [Cross-project isolation](#cross-project-isolation)), not a bug, and the two
options above are the way out of it.

---

## Daily use

| Command | What it does |
| --- | --- |
| `dev-sandbox` | Mount the current directory, open a shell |
| `dev-sandbox -Claude` | Same, but launch Claude Code with `--dangerously-skip-permissions` |
| `dev-sandbox -Port 5173` | Publish a different port |
| `dev-sandbox -Port 3000,5173,8080` | Publish several |
| `dev-sandbox -Port 8081:8080` | Remap when the host port is already taken |
| `dev-sandbox -Path ..\other-repo` | Mount somewhere other than the current folder |
| `dev-sandbox -Command "npm ci"` | Run one command instead of a shell |
| `dev-sandbox -Isolated` | Throwaway home + `node_modules` volumes, for untrusted third-party code |
| `dev-sandbox -ClaudeAuth` | Log in once on Windows so no sandbox ever asks again |
| `dev-sandbox -Persist` | Keep the container running after this shell exits |
| `dev-sandbox -Stop` | Shut the container down |

Default published ports are **3000, 5173, 8080** (Next/CRA, Vite, and a generic
spare). Publishing an unused port costs nothing, so you rarely need `-Port` at all.

### Multiple prompts in the same sandbox

Each `dev-sandbox` invocation `exec`s a new shell into the project's container,
creating it first if needed. So: open a second PowerShell window, `cd` to the same
project, type `dev-sandbox`, and you get a second independent prompt in the *same*
container — sharing the same filesystem, the same processes, and the same localhost.

A typical layout is three windows: `npm run dev` in one, `claude` in another,
`git`/`npm` in a third.

Two consequences:

- **The container stops itself once the last shell exits.** With three windows open,
  closing one leaves the container running for the other two; closing the last one
  stops it (and your dev server with it). Pass `-Persist` to keep it running solo,
  e.g. for a long build you want to walk away from.
- **Published ports are fixed when the container is created.** If you ask for a port
  that is not published, the banner tells you so; run `dev-sandbox -Stop` and start
  again with the port you want.

Each project gets its own container, named `dev-sandbox-<folder>-<hash>` — the hash
is derived from the full path, so two projects with the same folder name never
collide.

### Previewing the app

Start the dev server inside the container, then open `http://localhost:3000` in your
normal Windows browser.

> **⚠️ The one gotcha that will waste your afternoon**
>
> **A dev server must bind `0.0.0.0`, not `127.0.0.1`, or it is invisible from the
> Windows browser** even though the port is published. Inside the container,
> `127.0.0.1` means *the container's own loopback*, which the port forward never
> touches.
>
> - Node's `server.listen(3000)` with no host argument is **already correct**.
> - Vite: `npm run dev -- --host` (or `server.host: true` in `vite.config`).
> - Next.js: `next dev -H 0.0.0.0`.
> - `create-react-app`: `HOST=0.0.0.0 npm start`.
>
> Quick check from inside the container: `ss -ltnp` — you want `0.0.0.0:3000` or
> `*:3000`, not `127.0.0.1:3000`.

---

## How the boundary is drawn

### The mount

Exactly one project directory is bind-mounted, at `/workspace`. Nothing above it
exists inside the container — `/workspace/..` is the container's own root
filesystem, not your Documents folder. The wrapper refuses to mount the root of any drive,
`C:\Users`, or any user profile under it.

Also absent, deliberately: no Docker socket mount (which would be a trivial root
escape), no `--privileged`, no added capabilities, and `--security-opt
no-new-privileges` is set.

### `node_modules` is shadowed

A container-only volume is mounted over `/workspace/node_modules`, so the container
and Windows keep **separate dependency trees**. This is not optional hygiene: a
Windows `npm install` produces Windows-native binaries and `.cmd` shims that break
under Linux, and vice versa.

So the first time you enter a project, run `npm ci` (or `npm install`) *inside* the
container. Your Windows-side `node_modules` is untouched and still works for
Windows-side commands. `-SharedModules` turns the shadowing off if you only ever run
npm from one side.

If `npm install` ever fails with `EACCES ... mkdir '/workspace/node_modules/...'`,
the volume is owned by root instead of the `node` user. The wrapper fixes ownership
when it creates a container, so `dev-sandbox -Stop` followed by `dev-sandbox`
resolves it without losing the volume.

**Monorepos:** every `package.json` under the project (e.g. `v1/package.json`,
`packages/*/package.json`) gets its own volume shadowing its `node_modules`, found
by scanning the project when the container is created. Adding a new nested
workspace later needs `dev-sandbox -Fresh` to pick it up.

### Cross-project isolation

Each project gets its own home volume, `dev-sandbox-home-<slug>`, mounted at
`/home/node`. This matters because Claude Code writes full session transcripts to
`~/.claude/projects/<path>/*.jsonl` and a project registry to `~/.claude.json`. With
a single shared home volume, a Claude session in repo B could read repo A's
transcripts — they would sit in its own home directory. Per-project volumes remove
that channel entirely.

This is also why a login done *inside* a sandbox only sticks for that project: the
credentials Claude Code writes live in that project's home volume. Forward auth from
the host instead (`dev-sandbox -ClaudeAuth`, or `ANTHROPIC_API_KEY`) and the question
goes away without weakening the isolation — nothing is shared between projects except
an environment variable you already own.

`-SharedHome` opts back into one shared volume if you want shared settings across
projects and are comfortable with that trade. It shares transcripts too, so it is the
wrong tool for merely sharing a login.

`-Isolated` goes the other way: throwaway home *and* `node_modules` volumes that
`-Stop` deletes. They are separate from the ones an ordinary run of the same
project uses, so nothing an untrusted `npm install` fetched is still mounted the
next time you open a normal sandbox there.

### Git

The container has **no git credentials**. It can `status`, `diff`, `log`, `stash`,
and commit locally (your `user.name`/`user.email` are copied from your host git
config as environment variables — identity only, no secrets), but it cannot push.

Commits and pushes happen on Windows, in GitHub Desktop, as usual. The bind mount
means GitHub Desktop sees every file the container writes, immediately.

The image sets `safe.directory` globally, because a Windows bind mount shows up as
root-owned inside the container and git would otherwise refuse to touch it as
"dubious ownership".

### What Claude Code writes into your project

Two things worth knowing, since they land in the bind mount and therefore in front
of GitHub Desktop:

- `.claude/settings.local.json` — machine-local settings. Usually worth gitignoring.
- `CLAUDE.md` — project instructions. Usually worth *committing*.

Neither contains credentials.

---

## Honest security note

**This is isolation, not a hardened security boundary.**

Container escapes exist and are found regularly. What you get here is a meaningful
reduction in blast radius — an agent that goes wrong can trash the mounted project
and nothing else it can see — plus a genuinely useful second layer, because Docker
Desktop runs everything inside a WSL2 virtual machine rather than directly on the
Windows kernel.

That combination is solid for the actual use case: **letting an agent loose on your
own code without risking the rest of your machine.** It is *not* sufficient for
deliberately running code you believe to be malicious. For that you want a
disposable VM, and ideally not one sharing a kernel with anything you care about.

Specifically:

- **Network access is unrestricted by default.** It has to be — the Claude API and
  the npm registry both need it. Anything running in the container can reach the
  internet and can reach services listening on your Windows host.
- **Your API key or OAuth token is in the container's environment**, readable by any
  process in it. That is the cost of not re-authenticating per project — and it
  applies to `-Isolated` containers too, so drop the variable from that shell
  (`$env:CLAUDE_CODE_OAUTH_TOKEN = $null`) before sandboxing code you actually
  distrust.
- The `node` user is unprivileged and cannot `sudo`, but that is a speed bump, not a
  boundary.

Use `-Isolated` and a fresh container for anything you actually distrust, and
`dev-sandbox -Stop` when you are done with it.

---

## Maintenance

### Add a system package for a one-off project

The `node` user cannot `sudo`. Install as root in the running container — the change
lasts until the container is removed:

```powershell
docker exec -u root -it dev-sandbox-<slug> apt-get update
docker exec -u root -it dev-sandbox-<slug> apt-get install -y imagemagick
```

Find `<slug>` with `docker ps`. If you need the package permanently, add it to the
`apt-get install` line in the `Dockerfile` — the wrapper notices the change by hash
and rebuilds on your next `dev-sandbox`.

### Use a different Node version

```powershell
dev-sandbox -NodeVersion 22
```

Builds and uses a separate `dev-sandbox:node22` image. The `Dockerfile` pins
`node:24-trixie-slim` by default — `-trixie-` rather than bare `-slim` so a future
Debian default swap cannot silently change the base, and deliberately not Alpine,
because musl breaks Claude Code's bundled ripgrep.

### Reset everything

```powershell
# containers
docker ps -aq --filter "name=dev-sandbox-" | ForEach-Object { docker rm -f $_ }

# volumes (home + node_modules for every project -- you will re-login and re-npm-install)
docker volume ls -q --filter "name=dev-sandbox-" | ForEach-Object { docker volume rm $_ }

# images
docker images -q dev-sandbox | ForEach-Object { docker rmi -f $_ }

# rebuild
cd C:\Users\[user]\Documents\GitHub\docker-dev-sandbox
.\dev-sandbox.ps1 -Rebuild -Command "node --version"
```

To reset just one project, `dev-sandbox -Stop` then remove that project's volumes
(`docker volume ls --filter name=dev-sandbox-` to find them: a home volume, plus one
per `package.json` whose `node_modules` is shadowed). `-Isolated` volumes need no
cleanup -- `-Stop` already removes them.

### Requirements

Windows 11 with Docker Desktop (WSL2 backend) and Windows PowerShell 5.1. The
wrapper is written for 5.1 specifically — no `&&`, no ternary, no `??`. Nothing is
pushed to any registry; the only network fetch is the anonymous pull of the `node`
base image.
