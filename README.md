# My xbps repo

My personal Void Linux package repo, packages are built and updated automatically

## Add it
```sh
echo "repository=https://github.com/OWNER/REPO/releases/download/repo" | sudo tee /etc/xbps.d/10-mine.conf
sudo xbps-install -S    
```

## Packages
| Package | Upstream |
|---|---|
| noctalia | noctalia-dev/noctalia |
| noctalia-greeter | noctalia-dev/noctalia-greeter |

New upstream releases are built automatically and are UNTESTED.
