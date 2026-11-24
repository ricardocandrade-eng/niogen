// NIOGEN | tests/mari_n02b8_local_idioma.test.js | 23/11/2026 — Claude Code / Fable 5.2 (L-259: áudio transcrito em outro idioma)
// Sem API: node tests/mari_n02b8_local_idioma.test.js
// No L-259, 4 de 6 áudios curtos voltaram do transcritor em inglês, francês ou espanhol (o cliente falava português) e foram para a
// Mari como se fossem a fala do cliente. Transcrição que não é português = áudio não entendido: não vai para a IA, o cliente recebe
// o pedido de repetir ou escrever (2c) e o motivo fica gravado. As frases abaixo são inventadas (nenhuma é de cliente).
const fs = require('fs');
const assert = require('assert');
const c8 = fs.readFileSync('n8n/mari/n02b8_juntar.js', 'utf8');
const c2c = fs.readFileSync('n8n/mari/n02c_midia.js', 'utf8');
function juntar(transcricao, texto, doChatwoot) {
  const anexo = { n: 1, tipo: 'audio', mime: 'audio/ogg', ext: 'ogg', tamanho: 9000, url: 'https://x/a.ogg', cw_transcricao: doChatwoot ? transcricao : null, baixar: true };
  const nodes = {
    '2 · Entrada': [{ texto: texto == null ? '[MIDIA:audio]' : texto, anexos: [anexo], conversa_id: 'c1' }],
    '2b · Anexos': [{ n: 1, tipo: 'audio', caminho: 'mari/c1/1_1.ogg', transcrever: !doChatwoot }],
    '2b2 · Subir mídia': [{ Key: 'midia_conversas/mari/c1/1_1.ogg' }],
    '2b3 · Link IA': [{}],
    '2b7 · Transcrever': doChatwoot ? [] : [{ text: transcricao }],
  };
  const $ = (n) => ({ first: () => ({ json: (nodes[n] || [{}])[0] }), isExecuted: !!nodes[n], all: () => (nodes[n] || []).map((j) => ({ json: j })) });
  return new Function('$', c8)($)[0].json;
}
function midia2c(mensagem, midia) {
  const nodes = { '4 · Preparar': { conversa_id: 'c1', consolidado: { mensagem, midia, turno_ids: [1] } } };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }) });
  return new Function('$', c2c)($)[0].json;
}
let falhas = 0;
function caso(nome, f) { try { f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); } }

const ESTRANGEIRAS = ['what\'s the', 'Thank you for watching.', 'Posso empezar', 'Kayak, c\'est. Et Manuel. S\'il vous plaît, faites-moi un favor, éviter à compte.',
  'Gracias por ver el video', 'Merci d\'avoir regardé'];
for (const t of ESTRANGEIRAS) {
  caso(`outro idioma não vai para a Mari: «${t.slice(0, 30)}»`, () => {
    const r = juntar(t);
    const m = r.midia[0];
    assert.ok(!m.transcricao, `ficou com transcrição: ${m.transcricao}`);
    assert.match(m.erro || '', /outro idioma/);
    assert.strictEqual(m.transcricao_descartada, t);
    assert.ok(/\[MIDIA:audio\]/.test(r.texto) && !/🎤/.test(r.texto), `texto: ${r.texto}`);
  });
}
const PORTUGUES = ['Eu não sei o CEP. Se procurar aí o nome da rua, consegue achar o CEP?', 'Sim', 'Não', 'Boleto', 'Manhã', 'Ok',
  'Rua das Flores, 120', 'Maria Aparecida da Silva', 'trinta e seis, zero trinta e cinco, cento e trinta', 'Meu e-mail é maria arroba gmail ponto com',
  'Quero o plano de 500 mega com wi-fi', 'Rua Buenos Aires, número 40, perto da igreja El Shaday', 'três', 'Pode ser no cartão', 'Bom dia, tudo bem?',
  'Eu fui entrar porque é comum eu tentar ligar e ninguém fala nada, manda conta nem nada.'];
for (const t of PORTUGUES) {
  caso(`português segue para a Mari: «${t.slice(0, 30)}»`, () => {
    const r = juntar(t);
    assert.strictEqual(r.midia[0].transcricao, t);
    assert.ok(!r.midia[0].erro, `erro: ${r.midia[0].erro}`);
    assert.strictEqual(r.texto, `🎤 (áudio) ${t}`);
  });
}
caso('transcrição do próprio Chatwoot em outro idioma também é descartada', () => {
  const r = juntar('Thank you for watching.', null, true);
  assert.ok(!r.midia[0].transcricao); assert.match(r.midia[0].erro || '', /outro idioma/);
});
caso('cliente escreveu e mandou áudio não entendido: o texto dele segue', () => {
  const r = juntar('what\'s the', 'Meu CEP é 36010-000\n[MIDIA:audio]');
  assert.match(r.texto, /Meu CEP é 36010-000/); assert.ok(!/what/.test(r.texto));
});
// 2c: a frase fixa de áudio não entendido pede para repetir ou escrever (não diz que "não consegue ouvir esse tipo de mensagem")
caso('2c: áudio não entendido → pede para mandar de novo ou escrever', () => {
  const r = juntar('what\'s the');
  const s = midia2c(r.texto, r.midia);
  assert.match(s.texto, /não consegui entender/i); assert.match(s.texto, /escrev/i);
  assert.ok(s.erro && /outro idioma/.test(s.erro.mensagem), 'sem o motivo no erro');
});
caso('2c: vídeo ou documento continua com a frase de sempre', () => {
  const s = midia2c('[MIDIA:video]', [{ tipo: 'video' }]);
  assert.match(s.texto, /não consigo ouvir ou abrir esse tipo de mensagem/);
});
caso('2c: figurinha sozinha continua sem resposta', () => {
  const s = midia2c('[MIDIA:sticker]', [{ tipo: 'figurinha' }]);
  assert.strictEqual(s.texto, '');
});
console.log(falhas ? `\n${falhas} FALHA(S)` : '\ntudo verde');
process.exit(falhas ? 1 : 0);
