/**
 * Receptor de alertas minimalista para demo local.
 * Ejecutar: node scripts/webhook-receiver.js
 * Escucha en http://localhost:5001/alert y loggea cada alerta recibida.
 */
const http = require('http');

const PORT = 5001;

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(404);
    res.end();
    return;
  }
  let body = '';
  req.on('data', chunk => (body += chunk));
  req.on('end', () => {
    try {
      const payload = JSON.parse(body);
      const ts      = new Date().toISOString();
      console.log('\n' + '='.repeat(60));
      console.log('ALERTA RECIBIDA:', ts);
      console.log('Status:', payload.status);
      (payload.alerts || []).forEach(a => {
        const status    = a.status.toUpperCase();
        const name      = a.labels.alertname;
        const severity  = a.labels.severity;
        const job       = a.labels.job || '-';
        const summary   = (a.annotations || {}).summary || '';
        console.log(`  [${status}] ${name} | severity=${severity} | job=${job}`);
        console.log(`           ${summary}`);
      });
    } catch (e) {
      console.log('payload sin parsear:', body.slice(0, 200));
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
  });
});

server.listen(PORT, () =>
  console.log(`Receptor de webhooks escuchando en http://localhost:${PORT}/alert`)
);
