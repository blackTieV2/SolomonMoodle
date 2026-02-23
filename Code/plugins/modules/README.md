# Moodle module plugins

Each plugin is a small Bash file that registers additional Moodle module types
for `extract-resources.sh` to detect.

## Create a plugin

1. Copy the sample file:

   ```bash
   cp example-module.sh.sample my-module.sh
   ```

2. Edit the values (module name + regex pattern).
3. Re-run `moodle.sh` (or `extract-resources.sh`) and the module will be picked up.

## Notes

* Plugins must call `register_module`.
* The regex pattern should match the **relative** Moodle path, with slashes
  escaped for `grep -P`.
* By default, custom modules are only included with `--all` or `--modules`.
