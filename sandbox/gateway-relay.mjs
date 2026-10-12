#!/usr/bin/env node
// The container's relay to the owner's gateway, started by entrypoint.sh in the gateway shape. It is the
// one process that holds the client certificate and the role's token: tools that cannot present a client
// certificate themselves (gh, npm) and every other tool talk HTTPS to the gateway's subdomain names as
// usual; the firewall redirects those connections (port 443 to the gateway's address) here, this relay
// terminates them with a certificate for *.<domain> signed by a CA made at this container's start and
// trusted by the tools alone, adds `Proxy-Authorization: Bearer <token>` (the header the gateway consumes
// and never forwards), and re-originates each request over mutual TLS to the gateway's port 8443, the one
// port the firewall does not redirect, verifying the gateway against the owner's private root. Bodies and
// responses are piped byte for byte (git's packs, the model's event streams). It listens on the loopback
// only and proxies nothing but the gateway's names. Arguments: <relay dir> <gateway files dir> <address>
// <domain> [listen port, 8443] [gateway port, 8443].
import fs from 'node:fs';
import https from 'node:https';

const [relayDir, gwDir, address, domain, listenArg, gatewayArg] = process.argv.slice(2);
if (!relayDir || !gwDir || !address || !domain) { console.error('relay: usage: gateway-relay.mjs <relay dir> <gateway dir> <address> <domain> [listen port] [gateway port]'); process.exit(1); }
const listenPort = Number(listenArg || 8443);
const gatewayPort = Number(gatewayArg || 8443);
const leaf = { key: fs.readFileSync(`${relayDir}/leaf.key`), cert: fs.readFileSync(`${relayDir}/leaf.crt`) };
const client = { ca: fs.readFileSync(`${gwDir}/root.crt`), cert: fs.readFileSync(`${gwDir}/client.crt`), key: fs.readFileSync(`${gwDir}/client.key`) };
const token = fs.readFileSync(`${gwDir}/client.token`, 'utf8').trim();
const suffix = `.${domain}`;
const log = (line) => console.log(JSON.stringify({ ts: new Date().toISOString(), ...line }));

// One keep-alive agent carrying the client identity; every upstream request goes through it.
const agent = new https.Agent({ keepAlive: true, minVersion: 'TLSv1.3', ...client });

const server = https.createServer(leaf, (req, res) => {
  const host = String(req.headers.host || '').split(':')[0];
  const started = Date.now();
  if (!host.endsWith(suffix)) { res.writeHead(421, { 'content-type': 'text/plain' }); res.end('relay: not a gateway host\n'); return log({ host, method: req.method, path: req.url, status: 421 }); }
  const headers = { ...req.headers, host, 'proxy-authorization': `Bearer ${token}` };
  delete headers.connection;
  delete headers.expect; // answered here (Node sends 100 Continue itself); the gateway gets the body as it streams
  const up = https.request({ host: address, port: gatewayPort, servername: host, method: req.method, path: req.url, headers, agent }, (upRes) => {
    const out = { ...upRes.headers };
    delete out.connection;
    res.writeHead(upRes.statusCode, out);
    upRes.pipe(res);
    upRes.on('end', () => log({ host, method: req.method, path: req.url, status: upRes.statusCode, ms: Date.now() - started, id: upRes.headers['x-request-id'] }));
  });
  up.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`relay: ${err.message}\n`);
    log({ host, method: req.method, path: req.url, status: 502, error: err.message });
  });
  req.pipe(up);
});
server.on('tlsClientError', (err) => log({ tls: err.message }));
server.listen(listenPort, '127.0.0.1', () => log({ listening: `127.0.0.1:${listenPort}`, names: `*${suffix}`, gateway: `${address}:${gatewayPort}` }));
