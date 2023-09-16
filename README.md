
**Utils**
----
Various utilities Collection:

 - `bw_bck.sh`:  Perform exncrypted export of bitwarden ( password manager ) database without exposing password or related authentication token:
``` bash
# If you *don't* have a *working* bitwarden session key start from here:

# Configure bw ( If you haven't did it before )
$ bw config server https://example.com

# Login to bitwarden via the method you prefer ( Eg apikey )
$ bw login --apikey

# Unlock the vault and get the session keys.
# ( save the session key somewhere, you can reuse it )
$ bw unlock 

# If you have a *working* bitwarden session key start from here:

# Start ( in a tmux, or screen, session ) the script 
$ ./bw_bck.sh -s /mnt/Nas/bitwarden_export -p /tmp

# Now it require the session key. Paste it (Note echo is off)
Session key:

# After pasting the session key it will print:
session key taken successfully

# Now any time you want to start an export send a USR1 signal to the pid
# written in /tmp/bw_bck.pid ( by default write pid to /run, but require to be root )
# Eg:
$ kill -USR1 "$(cat /tmp/bw_bck.pid)"

# put it in a crontab to export the vault once per hours:
$ crontab -e
...
*/60 * * * * kill -USR1 "$(cat /tmp/bw_bck.pid 2>/dev/null)" 2>/dev/null 
```
