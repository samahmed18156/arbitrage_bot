# Windows 10 setup (4 GB RAM) — use PowerShell, no WSL

Skip WSL2: it reserves RAM and needs virtualisation turned on in BIOS. Everything here runs natively.

## 1. Rust  (you're doing this)
* Let the Visual Studio Installer finish, go back to the black `rustup-init` window, press **Enter** on "1) Proceed with standard installation".
* **Close PowerShell / Cursor and reopen them**, then check:
  ```powershell
  rustc --version
  cargo --version
  ```

## 2. Git for Windows
Download from https://git-scm.com/download/win (all defaults are fine). Check: `git --version`

## 3. Foundry (Solidity tooling) — zip method
1. Go to https://github.com/foundry-rs/foundry/releases/latest
2. Download `foundry_stable_win32_amd64.zip` (file name may differ slightly - look for win32 + amd64).
3. Extract to `C:\foundry`  (you should see forge.exe, cast.exe, anvil.exe)
4. Add it to PATH: Start menu -> "Edit the system environment variables" -> Environment Variables ->
   under *User variables* select `Path` -> Edit -> New -> `C:\foundry` -> OK.
5. **Open a new PowerShell**, check: `forge --version`

## 4. Project
Unzip `arb-bot.zip` somewhere like `C:\arb-bot` (NOT Downloads, NOT inside OneDrive).

```powershell
cd C:\arb-bot\contracts
forge test                     # 9 tests should pass, ~1 s

cd C:\arb-bot\bot
copy config.example.toml config.toml
cargo build --release          # first time: 5-15 min on your CPU. Close Cursor + other apps first.
.\target\release\arb-bot.exe config.toml      # scan-only, needs no wallet
```
Stop the bot with Ctrl+C.

## 5. Cursor settings (Ctrl+Shift+P -> "Open User Settings (JSON)")
```json
{
  "rust-analyzer.numThreads": 1,
  "rust-analyzer.cachePriming.enable": false,
  "rust-analyzer.check.command": "check",
  "rust-analyzer.lru.capacity": 64,
  "files.watcherExclude": { "**/target/**": true, "**/out/**": true, "**/lib/**": true }
}
```
Extensions: rust-analyzer + "Solidity" by Nomic Foundation. Nothing else.

## 6. Environment variables in PowerShell (later, for live mode)
```powershell
$env:PRIVATE_KEY = "0x..."     # lasts for this window only; never put it in a file or chat
```

## Safety on this PC
This machine also runs your POS software. Don't put a wallet private key on a shared/business PC.
Use scan-only mode and the local fork (fake keys) here. If you go live later, use a fresh wallet with ~$5-10.
