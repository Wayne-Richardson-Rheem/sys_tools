#!/bin/bash
set -e

echo "=== Updating system ==="
sudo apt update
sudo apt install -y apache2 openssl network-manager iw

echo "=== Enabling NetworkManager (if not enabled) ==="
sudo systemctl enable --now NetworkManager || true
sudo systemctl disable --now wpa_supplicant || true
sudo systemctl disable --now dhcpcd || true

echo "=== Creating SSL directory ==="
sudo mkdir -p /etc/apache2/ssl

echo "=== Generating self-signed SSL certificate ==="
sudo openssl req -x509 -nodes -days 3650 \
  -newkey rsa:2048 \
  -keyout /etc/apache2/ssl/server.key \
  -out /etc/apache2/ssl/server.crt \
  -subj "/C=US/ST=Arkansas/L=FortSmith/O=RheemFSM/OU=HVAC/CN=raspberrypi.local"

echo "=== Enabling Apache SSL & CGI ==="
sudo a2enmod ssl
sudo a2enmod cgi

echo "=== Installing HTTPS virtual host ==="
sudo tee /etc/apache2/sites-available/default-ssl.conf >/dev/null <<'EOF'
<IfModule mod_ssl.c>
<VirtualHost _default_:443>
    ServerAdmin webmaster@localhost

    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile      /etc/apache2/ssl/server.crt
    SSLCertificateKeyFile   /etc/apache2/ssl/server.key

    <Directory "/usr/lib/cgi-bin">
        Options +ExecCGI
        AddHandler cgi-script .py
        Require all granted
    </Directory>

    ScriptAlias /cgi-bin/ /usr/lib/cgi-bin/
</VirtualHost>
</IfModule>
EOF

echo "=== Enabling the HTTPS site ==="
sudo a2ensite default-ssl

echo "=== Redirecting all HTTP → HTTPS ==="
sudo tee /etc/apache2/sites-available/000-default.conf >/dev/null <<'EOF'
<VirtualHost *:80>
    Redirect permanent / https://%{HTTP_HOST}/
</VirtualHost>
EOF

echo "=== Deploying index.html ==="
sudo mkdir -p /var/www/html
sudo tee /var/www/html/index.html >/dev/null <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width,initial-scale=1 .container { max-width: 420px; margin:auto; background:#fff; padding:20px; border-radius:8px; box-shadow: 0 0 10px rgba(0,0,0,.1); }
  h2 { text-align:center; margin-bottom:16px; }
  label { display:block; margin:10px 0 6px; }
  select, input[type="password"], button { width:100%; padding:10px; font-size:16px; }
  .row { display:flex; gap:8px; align-items:center; }
  .toggle { cursor:pointer; color:#0a58ca; user-select:none; }
  button { margin-top; }
  .note { font-size: 13px; color:#555; margin-top:8px; }
</style>
</head>
<body>
<div class="container">
  <h2>Configure Wi‑Fi</h2>
  <form id="wifiForm">
    <label for="ssid">Select SSID:</label>
    <select id="ssid" name="ssid">
      <option value="">Loading…</option>
    </select>

    <label for="password">Password:</label>
    <div class="row">
      <input type="password" id="password" name="password" placeholder="Enter Wi‑Fi password" />
      <span class="toggle" onclick="togglePassword()">Show</span>
    </div>
    <button type="submit">Connect</button>
    <div class="note" id="statusNote"></div>
  </form>
</div>

<script>
function togglePassword() {
  const pwd = document.getElementById('password');
  pwd.type = (pwd.type === 'password') ? 'text' : 'password';
}

function loadSSIDs() {
  fetch('/cgi-bin/networks.py')
    .then(r => r.json())
    .then(data => {
      const select = document.getElementById('ssid');
      select.innerHTML = '';
      if (!Array.isArray(data) || data.length === 0) {
        select.innerHTML = '<option value="">No networks found</option>';
        return;
      }
      data.forEach(item => {
        const opt = document.createElement('option');
        opt.value = item.ssid;
        const suffix = ('signal_percent' in item) ? `${item.signal_percent}%`
                     : ('signal_dbm' in item)     ? `${item.signal_dbm} dBm`
                     : '';
        opt.textContent = suffix ? `${item.ssid} (${suffix})` : item.ssid;
        select.appendChild(opt);
      });
    })
    .catch(err => console.error('Failed to load SSIDs:', err));
}
loadSSIDs();

document.getElementById('wifiForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const ssid = document.getElementById('ssid').value;
  const password = document.getElementById('password').value;
  if (!ssid || !password) { alert('Please select an SSID and enter a password.'); return; }
  if (!confirm(`Connect to "${ssid}" and disable AP once connected?`)) return;

  const body = new URLSearchParams({ssid, password});
  const res = await fetch('/cgi-bin/connect.py', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  });

  let text = await res.text();
  try {
    const j = JSON.parse(text);
    alert(j.message || text);
    document.getElementById('statusNote').textContent = j.message || '';
  } catch {
    alert(text);
    document.getElementById('statusNote').textContent = text;
  }
});
</script>
</body>
</html>
EOF

echo "=== Installing CGI scripts ==="
sudo cp networks.py /usr/lib/cgi-bin/networks.py
sudo cp connect.py  /usr/lib/cgi-bin/connect.py
sudo chmod 755 /usr/lib/cgi-bin/*.py
sudo chown root:root /usr/lib/cgi-bin/*.py

echo "=== Granting sudo access to nmcli & iw ==="
sudo tee /etc/sudoers.d/wifi-cgi >/dev/null <<'EOF'
www-data ALL=(root) NOPASSWD: /usr/bin/nmcli
www-data ALL=(root) NOPASSWD: /usr/sbin/iw
EOF

echo "=== Restarting Apache ==="
sudo systemctl restart apache2

echo "=== DONE! Visit the device at: ==="
echo "  https://<your-pi-ip>/"
echo "NOTE: Browser will warn about self-signed certificate – this is expected."
