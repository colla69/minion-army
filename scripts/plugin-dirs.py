"""Prints the folder of each plugin that a project enables, one per line, for `claude --plugin-dir`.

Claude Code loads a project-scope plugin only in the folder where it was installed, so an agent in a
worktree of the engine would run without the project's plugins. A plugin that is installed at user
scope loads everywhere, so it is left out. A plugin that is not installed on this machine is named on
stderr and left out, so that the run still starts.

Usage: python3 -I scripts/plugin-dirs.py <project settings.json> <installed_plugins.json>
"""
import json
import os
import sys


def main(settings_path, installed_path):
    try:
        with open(settings_path) as file:
            enabled = json.load(file).get("enabledPlugins", {})
    except FileNotFoundError:
        return
    with open(installed_path) as file:
        installed = json.load(file).get("plugins", {})

    for plugin, on in enabled.items():
        if on is not True:
            continue
        entries = installed.get(plugin, [])
        if any(entry.get("scope") == "user" for entry in entries):
            continue
        folders = [entry for entry in entries if os.path.isdir(entry.get("installPath", ""))]
        if not folders:
            print(f"The plugin {plugin} is not installed on this machine.", file=sys.stderr)
            continue
        newest = max(folders, key=lambda entry: entry.get("lastUpdated", ""))
        print(newest["installPath"])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
