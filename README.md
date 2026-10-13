# My XBPS repo

Auto-updating, auto-building Void Linux repo, hosted free on GitHub.
Based on HeavenDivided/void-repo (MIT). See LICENSE.

## Use it (users)
```sh
echo "repository=https://github.com/OWNER/REPO/releases/download/repo" | sudo tee /etc/xbps.d/10-mine.conf
sudo xbps-install -S     # confirm the key fingerprint when asked
```

## Packages
| Package | Upstream |
|---|---|
| noctalia | noctalia-dev/noctalia |
| noctalia-greeter | noctalia-dev/noctalia-greeter |

New upstream releases are built automatically and are UNTESTED.
