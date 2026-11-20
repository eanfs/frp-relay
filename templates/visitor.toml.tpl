serverAddr = "{{SERVER_ADDR}}"
serverPort = {{SERVER_PORT}}
user = "{{PROXY_USER}}"
loginFailExit = true
log.to = "console"
log.level = "info"

auth.method = "token"
auth.token = "{{TOKEN}}"
transport.tls.enable = true

[[visitors]]
name = "{{PROXY_NAME}}-stcp-visitor"
type = "stcp"
serverUser = "{{PROXY_USER}}"
serverName = "{{PROXY_NAME}}-stcp"
secretKey = "{{STCP_SECRET}}"
bindAddr = "127.0.0.1"
bindPort = {{STCP_BIND_PORT}}
