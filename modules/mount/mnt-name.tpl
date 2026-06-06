[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target

[Mount]
What=${source}
Where=${target}
Type=cifs
Options=credentials=/etc/smbcredentials/nas,vers=3.1.1,uid=${uid},gid=${gid}

[Install]
WantedBy=multi-user.target
