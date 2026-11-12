<h1><img src="assets/claude-logo.svg" alt="Claude" width="40" align="absmiddle"> maki-claude</h1>

Use a Claude Pro or Max subscription in [maki](https://github.com/tontinton/maki).
The package adds a `claude` provider that logs in with the same OAuth flow as
Claude Code. A subscription token is accepted when the system prompt opens with
the Claude Code identity line as its own block, which maki sends as the
provider's system prefix; nothing else about the request has to change.

## Requirements

- maki 0.7.0 or newer
- On Linux and macOS, `uname`, `sh` and `openssl` on `PATH`, used to log in
- On Windows, Windows PowerShell (`powershell.exe`) on `PATH`, used to log in
- A Claude Pro or Max subscription
- Windows, Linux or macOS

## Install

Add the package in `~/.config/maki/init.lua`:

```lua
maki.pack.add({
  { src = "https://github.com/bzzimmy/maki-claude", version = "main" },
})
```

## Setup

```
maki auth login claude
```

Login opens the browser. Approve the request, copy the code the page shows,
and paste it into the terminal. maki stores the tokens in its state directory,
with mode 0600 on Linux and macOS, and the plugin refreshes them on its own.

On any other system, login stops with a message that names the supported
systems, and maki shows the same message when you use a Claude model before
you log in. A missing tool stops the login with a message that names it.

Pick a model with `/model`. The list comes from your subscription at runtime,
under the `claude/` prefix. Like Claude Code, a model with a 1M context window
is offered only with it, for example `claude/claude-opus-5-5-1m`.

- `maki auth logout claude` removes the stored tokens.
- maki's own usage display shows the subscription quota.

## Permissions

The package requests exactly what it calls: `net` for the API, the model list, and the
token endpoint at `api.anthropic.com`, `run` to detect the system and create the login
PKCE pair, and `env` to read the `OS` and `CLAUDE_ATIS` variables.

## Development

Clone the repository and run the checks from its root. The Rust tests load
the package through the real maki Lua host and need `cargo-nextest`.

```sh
git clone https://github.com/bzzimmy/maki-claude.git
cd maki-claude
just check && just lint && just test
```
