// NIOGEN | tests/osab_formatos.js | 13/11/2026 — Claude Code (docs/Prompt_operador_os_etapa3_131126_0300.md, Parte B)
// Testa o importador do OSAB (docs/assets/osab.js) como peça isolada (regra 15), nos dois formatos:
//   1. 'email'  — contra o exemplo da pasta referencia-nio (fora do repo): OSAB_28-09-26.xlsx
//   2. 'painel' — a tabela "Exportação - OSAB" do painel Performance em Foco. O arquivo de teste é MONTADO AQUI, com as
//                 33 colunas vistas no levantamento de 13/11 e dados inventados (nenhum dado real da Nio entra no repo).
//   3. opcional — um arquivo real, só para conferir a leitura (nada é copiado): OSAB_REAL=C:\caminho\arquivo.xlsx
// Uso:  set NODE_PATH=<pasta com node_modules/xlsx>   (npm i https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz)
//       set OSAB_REF=C:\...\referencia-nio\OSAB_28-09-26.xlsx   (sem ela, o caso 1 é pulado e avisa)
//       node tests/osab_formatos.js     → "VERDE" e código 0, ou a lista do que falhou e código 1.
'use strict';
const fs = require('fs');
const path = require('path');
const XLSX = require('xlsx');
global.XLSX = XLSX;
const { ler, classificar } = require(path.join(__dirname, '..', 'docs', 'assets', 'osab.js'));

const falhas = [];
const ok = (cond, nome) => { console.log((cond ? '  ok   ' : '  FALHOU ') + nome); if (!cond) falhas.push(nome); };
const buf = (wb) => XLSX.write(wb, { type: 'array', bookType: 'xlsx' });
const serial = (y, m, d, h = 0, mi = 0) => (Date.UTC(y, m - 1, d, h, mi) / 86400000) + 25569;

// ------------------------------------------------------------------ 1. formato do e-mail (referência)
console.log('1. OSAB do e-mail (referencia-nio)');
const ref = process.env.OSAB_REF;
if (ref && fs.existsSync(ref)) {
  const r = ler(fs.readFileSync(ref));
  ok(!r.erro, 'lê sem erro');
  ok(r.fonte === 'email', "fonte = 'email'");
  ok(r.lidas === 8569, `8.569 linhas lidas (leu ${r.lidas})`);
  ok(r.situacoes['Concluído'] === 6294 && r.situacoes['Cancelado'] === 1347, 'situações: 6.294 concluídas, 1.347 canceladas');
  ok(r.linhas.every((o) => o.fonte === undefined), 'linha do e-mail não leva os campos do painel (o banco assume fonte = email)');
  // O exemplo veio anonimizado com o MESMO número de pedido em todas as linhas: sobra 1 pedido distinto.
  ok(r.linhas.length === 1 && r.duplicadas === 8568, 'exemplo anonimizado: 1 pedido distinto, 8.568 repetidas');
} else {
  console.log('  (OSAB_REF não informado ou não existe: caso 1 PULADO)');
  falhas.push('caso 1 pulado: informe OSAB_REF');
}

// A regra do e-mail não mudou: concluído só avança com venda válida.
const email = (situacao, valida) => ({ situacao, venda_valida: valida, data_fechamento: '2026-09-20T10:00:00-03:00' });
ok(classificar(email('Concluído', true), { status: '2_aguardando_instalacao' }).para === '4_ativo_provisorio', 'e-mail: concluído + válida → ativo');
ok(classificar(email('Concluído', false), { status: '2_aguardando_instalacao' }).para === null, 'e-mail: concluído + inválida não avança');
ok(classificar(email('Concluído', null), { status: '2_aguardando_instalacao' }).para === null, 'e-mail: concluído sem a validade não avança');
ok(classificar(email('Concluído', false), { status: '2_aguardando_instalacao' }).risco === true, 'e-mail: inválida é risco');

// ------------------------------------------------------------------ 2. formato do painel (montado aqui)
console.log('2. OSAB do painel (Exportação - OSAB)');
const CAB = ['REDE', 'DATA HORA - Atualização', 'DATA VENDA', 'NR ORDEM', 'NR ORDEM ORIGINAL', 'SEGMENTO', 'TP MEI', 'UF', 'MUNICIPIO',
  'CELULA', 'VELOCIDADE', 'PLANO', 'MÉTODO PGTO', 'CAMPANHA', 'MATRICULA VENDEDOR', 'STATUS', 'DATA ATIVACAO', 'MOTIVO ORDEM',
  'SUB MOTIVO', 'DETALHE MOTIVO', 'TIPO CDO', 'SAP', 'NR BA', 'DATA BA', 'DATA AGENDAMENTO', 'PENDENCIA BA', 'STATUS BA', 'ESTADO BA',
  'MOTIVO BA', 'FAIXA AGENDAMENTO', 'INÍCIO EXECUÇÃO REAL', 'FIM EXECUÇÃO REAL', 'FAIXA HORA EXECUÇÃO'];
const linha = (o) => CAB.map((c) => (o[c] === undefined ? null : o[c]));
const base = { REDE: 'PARCEIRO TESTE', 'DATA HORA - Atualização': serial(2026, 11, 13, 8, 25), 'DATA VENDA': serial(2026, 11, 10), SEGMENTO: 'Varejo',
  UF: 'MG', MUNICIPIO: 'CIDADE TESTE', VELOCIDADE: '600MB', PLANO: 'Legado', 'MÉTODO PGTO': 'Boleto Digital', 'MATRICULA VENDEDOR': 'TT000000', SAP: 1 };
const dados = [
  CAB,
  linha({ ...base, 'NR ORDEM': '90000001', STATUS: 'Em Aprovisionamento', 'NR BA': 'SA-1', 'DATA AGENDAMENTO': serial(2026, 11, 13, 8), 'ESTADO BA': 'ATRIBUÍDO', 'FAIXA AGENDAMENTO': '08:00 - 12:00' }),
  linha({ ...base, 'NR ORDEM': '90000002', STATUS: 'Concluído', 'DATA ATIVACAO': serial(2026, 11, 12), 'INÍCIO EXECUÇÃO REAL': serial(2026, 11, 12, 9, 10), 'FIM EXECUÇÃO REAL': serial(2026, 11, 12, 10, 40), 'ESTADO BA': 'CONCLUÍDO' }),
  linha({ ...base, 'NR ORDEM': '90000003', STATUS: 'Concluído' }),   // concluído SEM data: não avança sozinho
  linha({ ...base, 'NR ORDEM': '90000004', STATUS: 'Cancelado', 'MOTIVO ORDEM': 'Inviabilidade Total', 'SUB MOTIVO': 'Sem rede', 'DETALHE MOTIVO': 'CDO cheia' }),
  linha({ ...base, 'NR ORDEM': '90000005', STATUS: 'Pendência Cliente', 'PENDENCIA BA': 'LOCAL FECHADO' }),
  linha({ ...base, 'NR ORDEM': '90000004', 'DATA HORA - Atualização': serial(2026, 11, 12, 8, 0), STATUS: 'Em Aprovisionamento' }),   // repetida e mais antiga
  [],
  linha({ REDE: 'Filtros aplicados:\ncheck é ok\nANOMES é 202611' }),
];
const wb = XLSX.utils.book_new();
XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(dados), 'Export');
const p = ler(buf(wb));
ok(!p.erro, 'lê sem erro');
ok(p.fonte === 'painel', "fonte = 'painel'");
ok(p.lidas === 6 && p.semPedido === 0, `6 linhas de pedido; o rodapé "Filtros aplicados" não conta (leu ${p.lidas}, sem pedido ${p.semPedido})`);
ok(p.filtros && p.filtros.includes('ANOMES é 202611'), 'guarda os filtros aplicados do rodapé');
ok(p.linhas.length === 5 && p.duplicadas === 1, 'pedido repetido: fica um');
const por = Object.fromEntries(p.linhas.map((o) => [o.pedido, o]));
ok(por['90000004'].situacao === 'Cancelado', 'pedido repetido: vale a linha atualizada por último');
ok(p.dt_ref === '2026-11-13', 'DT_REF = dia da atualização');
const a = por['90000001'];
ok(a.data_agendamento === '2026-11-13T08:00:00-03:00', 'agendamento em hora de Brasília');
ok(a.estado_ba === 'ATRIBUÍDO' && a.faixa_agendamento === '08:00 - 12:00' && a.numero_ba === 'SA-1', 'andamento do BA lido');
ok(a.venda_valida === null && a.fonte === 'painel', 'sem fg_venda_valida no painel (nulo)');
ok(classificar(a, { status: '2_aguardando_instalacao' }).para === null, 'em aprovisionamento não muda o status');
const b = por['90000002'];
ok(b.data_fechamento === '2026-11-12T10:40:00-03:00', 'data real = fim da execução em campo');
ok(b.data_ativacao === '2026-11-12T00:00:00-03:00', 'data da ativação guardada');
ok(classificar(b, { status: '2_aguardando_instalacao' }).para === '4_ativo_provisorio', 'concluído com data real → ativo');
ok(classificar(b, { status: '1_vendido' }).para === null, 'a prévia segue a regra antiga para 1_vendido (o banco avança — 0153)');
ok(classificar(por['90000003'], { status: '2_aguardando_instalacao' }).para === null, 'concluído SEM data de ativação não avança');
const c4 = classificar(por['90000004'], { status: '2_aguardando_instalacao' });
ok(c4.para === 'saida' && c4.motivoSaida === 'Nio: Inviabilidade Total · Sem rede · CDO cheia', 'cancelado → saída com motivo, sub-motivo e detalhe');
const c5 = classificar(por['90000005'], { status: '2_aguardando_instalacao', nio_pendencia_cod: null, nio_pendencia_desc: null });
ok(c5.para === null && c5.pendencia === null, 'pendência do BA sem código não vira pendência do funil sozinha (fica no andamento da OS)');
ok(por['90000005'].desc_pendencia === 'LOCAL FECHADO', 'texto da pendência do BA guardado');

// arquivo que não é OSAB
const wb2 = XLSX.utils.book_new();
XLSX.utils.book_append_sheet(wb2, XLSX.utils.aoa_to_sheet([['A', 'B'], [1, 2]]), 'X');
ok(!!ler(buf(wb2)).erro, 'arquivo sem as colunas é recusado');

// ------------------------------------------------------------------ 3. arquivo real (opcional, só leitura)
const real = process.env.OSAB_REAL;
if (real && fs.existsSync(real)) {
  console.log('3. Arquivo real (só o resumo; nenhum dado é copiado)');
  const r = ler(fs.readFileSync(real));
  ok(!r.erro, 'lê sem erro' + (r.erro ? ': ' + r.erro : ''));
  if (!r.erro) {
    console.log(`  fonte ${r.fonte} · aba ${r.aba} · ${r.lidas} linha(s) · ${r.linhas.length} pedido(s) · DT_REF ${r.dt_ref}`);
    console.log('  situações: ' + JSON.stringify(r.situacoes));
    console.log('  estado do BA: ' + JSON.stringify(r.linhas.reduce((m, o) => { const k = o.estado_ba || '(vazio)'; m[k] = (m[k] || 0) + 1; return m; }, {})));
    console.log('  filtros: ' + (r.filtros || '—'));
  }
}

console.log();
if (falhas.length) { console.log(`VERMELHO — ${falhas.length} falha(s)`); process.exit(1); }
console.log('VERDE — importador do OSAB conferido nos dois formatos');
