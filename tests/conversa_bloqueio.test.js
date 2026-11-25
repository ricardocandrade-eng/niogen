// NIOGEN | tests/conversa_bloqueio.test.js — 24/11/2026: regra do selo "📵 Provável bloqueio" (docs/assets/conversa.js, bloqueioDe)
// Uso: node tests/conversa_bloqueio.test.js
const fs = require('fs');
const src = fs.readFileSync(require('path').join(__dirname, '..', 'docs/assets/conversa.js'), 'utf8');
const ini = src.indexOf('  function bloqueioDe(');
const fim = src.indexOf('  function seloBloqueio(');
const bloqueioDe = new Function(src.slice(ini, fim) + '; return bloqueioDe;')();
const H = 3600e3, agora = Date.parse('2026-11-27T12:00:00Z');
const m = (dir, status, horasAtras) => ({ direcao: dir, status, criado_em: new Date(agora - horasAtras * H).toISOString() });
const casos = [
  ['2 presas há +24 h depois do cliente', [m('in', 'enviada', 60), m('out', 'enviada', 50), m('out', 'enviada', 26)], 'preso'],
  ['só 1 presa', [m('in', 'enviada', 60), m('out', 'enviada', 50)], null],
  ['2 presas, mas uma com menos de 24 h', [m('in', 'enviada', 60), m('out', 'enviada', 50), m('out', 'enviada', 3)], null],
  ['uma entregue no meio', [m('out', 'enviada', 70), m('out', 'entregue', 50), m('out', 'enviada', 30)], null],
  ['cliente falou depois', [m('out', 'enviada', 70), m('out', 'enviada', 50), m('in', 'enviada', 30)], null],
  ['2 falharam', [m('in', 'enviada', 10), m('out', 'falhou', 5), m('out', 'falhou', 1)], 'falhou'],
  ['sem status (antes dos tiques) interrompe', [m('out', null, 90), m('out', 'enviada', 30)], null],
  ['3 presas sem fala do cliente nos dados', [m('out', 'enviada', 90), m('out', 'enviada', 60), m('out', 'enviada', 30)], 'preso'],
  ['vazio', [], null],
];
let ok = 0;
for (const [nome, l, esperado] of casos) {
  const r = bloqueioDe(l, agora);
  const tipo = r ? r.tipo : null;
  const passou = tipo === esperado;
  ok += passou;
  console.log(passou ? 'ok  ' : 'FALHOU', nome, '→', tipo);
}
console.log(ok === casos.length ? 'tudo verde' : `${casos.length - ok} falha(s)`);
process.exit(ok === casos.length ? 0 : 1);
