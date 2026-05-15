## 2024-05-14 - [CRITICAL] Prevented SSRF Bypass with IPv6 Support
**Vulnerability:** The initial SSRF fix in `mcp/url_policy.py` only used `socket.gethostbyname()`, which fails for IPv6 literals (e.g., `http://[::1]/`). Because the exception was silently caught to allow failing DNS, IPv6 internal requests bypassed the protection.
**Learning:** `socket.gethostbyname()` is insufficient for thorough SSRF checks since it only handles IPv4.
**Prevention:** Use `socket.getaddrinfo()` instead, which resolves both IPv4 and IPv6 addresses. Alternatively, use `ipaddress.ip_address` to directly parse and validate IPv6 literals if passed in the URL.
