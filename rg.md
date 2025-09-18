✅ Steps to Try Before Reinstalling
1. Temporarily disable search indexing
Open your workspace settings (.vscode/settings.json or in Viscose GUI) and add:
"search.followSymlinks": false,
"search.exclude": {
  "**/node_modules": true,
  "**/build": true,
  "**/.git": true,
  "**/__pycache__": true
}
If you’re in a Julia project:
"files.watcherExclude": {
  "**/compiled": true,
  "**/deps": true
}
2. Check what is triggering rg
Run this in terminal while the spamming happens:
ps aux | grep rg
You’ll get command-line arguments. Example:
rg --json --threads 1 --max-filesize 15M ...
Check:
Which path is being searched
If the process keeps spawning, then something is triggering it repeatedly
3. Disable extensions one by one
Start Viscose with extensions disabled:
code --disable-extensions
If that stops the rg spam — re-enable extensions one by one.
4. Exclude problematic folders from the workspace
Temporarily open a minimal folder or an empty one to see if the issue persists. If it doesn’t, your project folder contains something rg is choking on.
5. Throttle file watchers (on Linux/macOS)
Check fs.inotify.max_user_watches (on Linux) or if macOS has spotlight/indexing conflicts.
On macOS, run:
sudo mdutil -i off /path/to/your/project
6. Try --disable-workspace-trust (if you suspect reloads)
code --disable-workspace-trust
🧹 If nothing works: Clean reinstall
Before reinstalling Viscose:
Wipe ~/.config/Viscose or ~/Library/Application Support/Viscose (macOS)
Wipe cached extensions and workspaces
Then reinstall. But this should be your last resort — usually the problem is a recursive or large folder triggering indexing loops.
If you paste the ps aux | grep rg output or your .vscode/settings.json, I can give you precise advice.