serverAddr = "{{SERVER_ADDR}}"
serverPort = {{SERVER_PORT}}
user = "{{PROXY_USER}}"
loginFailExit = true
log.to = "console"
log.level = "info"

auth.method = "token"
auth.token = "{{TOKEN}}"
transport.tls.enable = true

webServer.addr = "127.0.0.1"
webServer.port = 7400
webServer.user = "{{PROXY_USER}}"
webServer.password = "{{ADMIN_PASSWORD}}"

# Public TCP path: the start script replaces 0 with a random unused port
# on every start, then prints it. status.cmd shows the current port.
[[proxies]]
name = "{{PROXY_NAME}}"
type = "tcp"
localIP = "{{INTERNAL_HOST}}"
localPort = {{SSH_PORT}}
remotePort = 0
transport.useEncryption = true

# STCP path: no public port; environment B runs the visitor.
[[proxies]]
name = "{{PROXY_NAME}}-stcp"
type = "stcp"
secretKey = "{{STCP_SECRET}}"
localIP = "{{INTERNAL_HOST}}"
localPort = {{SSH_PORT}}
allowUsers = ["{{PROXY_USER}}"]
