# Securius Hub

Install Securius Hub on your dedicated device using the command below:

```bash
curl -fsSL https://raw.githubusercontent.com/securius-core/securius-hub-install/main/install.sh | bash
```

## Network details

Before installing, check these against your network for conflicts.

**LAN IPs:** claimed automatically from the final-octet range **`.50`–`.98`** of
your /24 LAN. Keep your router's DHCP pool clear of that range to avoid conflicts.

**Ports:**

| Port | Proto | App |
|------|-------|-----|
| `48080` | tcp | Hub |
| `48081` | tcp | Shield |
| `48082`+ | tcp | Future products |
