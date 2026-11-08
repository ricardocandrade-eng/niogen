/* NIOGEN | docs/assets/markdown.js | 08/11/2026 — Claude Code (Guia do Backoffice no NIOGEN)
 * Renderizador de Markdown pequeno e local (sem CDN), para o texto da tabela conteudos (guia.html).
 * Cobre: títulos # a #### (com âncora {#id} opcional no fim), parágrafos, **negrito**, *itálico*, `código`, blocos ```,
 * listas com - * e 1. (um nível de recuo), > citação, tabelas | a | b |, --- e [links](url). Tudo é escapado antes:
 * HTML cru do texto vira texto. Links só http(s), âncora (#) ou página relativa .html.
 * Uso: NGMarkdown.render(md) → { html, titulos: [{ nivel, texto, id }] }
 */
(function () {
  'use strict';
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const slug = (s) => String(s).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'secao';

  function inline(t) {
    const codes = [];
    let s = esc(t).replace(/`([^`]+)`/g, (m, c) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, txt, url) => {
      const u = url.replace(/&amp;/g, '&');
      const ok = /^(https?:\/\/|#|[\w-]+\.html(#[\w-]+)?$)/i.test(u);
      if (!ok) return txt;
      const fora = /^https?:/i.test(u);
      return `<a href="${esc(u)}"${fora ? ' target="_blank" rel="noopener"' : ''}>${txt}</a>`;
    });
    s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>').replace(/(^|[^*\w])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>');
    return s.replace(/\u0000(\d+)\u0000/g, (m, i) => `<code>${codes[Number(i)]}</code>`);
  }

  function render(md) {
    const linhas = String(md || '').replace(/\r\n/g, '\n').split('\n');
    const out = [];
    const titulos = [];
    const usados = new Set();
    let i = 0;
    const celulas = (l) => l.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
    while (i < linhas.length) {
      const l = linhas[i];
      if (!l.trim()) { i += 1; continue; }
      // bloco de código
      if (/^```/.test(l)) {
        const buf = [];
        i += 1;
        while (i < linhas.length && !/^```/.test(linhas[i])) { buf.push(linhas[i]); i += 1; }
        i += 1;
        out.push(`<pre><code>${esc(buf.join('\n'))}</code></pre>`);
        continue;
      }
      // título
      const h = l.match(/^(#{1,4})\s+(.+?)\s*$/);
      if (h) {
        const nivel = h[1].length;
        let texto = h[2];
        let id = null;
        const a = texto.match(/\s*\{#([\w-]+)\}\s*$/);
        if (a) { id = a[1]; texto = texto.slice(0, a.index); }
        if (!id) id = slug(texto);
        let base = id, n = 2;
        while (usados.has(id)) { id = `${base}-${n}`; n += 1; }
        usados.add(id);
        titulos.push({ nivel, texto: texto.replace(/[*`]/g, ''), id });
        out.push(`<h${nivel} id="${esc(id)}">${inline(texto)}</h${nivel}>`);
        i += 1;
        continue;
      }
      if (/^\s*(---|\*\*\*)\s*$/.test(l)) { out.push('<hr>'); i += 1; continue; }
      // tabela: linha com | seguida de separador |---|
      if (l.includes('|') && i + 1 < linhas.length && /^\s*\|?\s*:?-{2,}/.test(linhas[i + 1])) {
        const cab = celulas(l);
        i += 2;
        const corpo = [];
        while (i < linhas.length && linhas[i].includes('|') && linhas[i].trim()) { corpo.push(celulas(linhas[i])); i += 1; }
        out.push(`<table><thead><tr>${cab.map((c) => `<th>${inline(c)}</th>`).join('')}</tr></thead><tbody>${
          corpo.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join('')}</tr>`).join('')}</tbody></table>`);
        continue;
      }
      // citação
      if (/^>\s?/.test(l)) {
        const buf = [];
        while (i < linhas.length && /^>\s?/.test(linhas[i])) { buf.push(linhas[i].replace(/^>\s?/, '')); i += 1; }
        const paras = buf.join('\n').split(/\n\s*\n/).map((p) => `<p>${p.split('\n').map(inline).join('<br>')}</p>`);
        out.push(`<blockquote>${paras.join('')}</blockquote>`);
        continue;
      }
      // lista (um nível de recuo)
      if (/^\s*([-*]|\d+\.)\s+/.test(l)) {
        const ord = /^\s*\d+\./.test(l);
        const itens = [];
        while (i < linhas.length && (/^\s*([-*]|\d+\.)\s+/.test(linhas[i]) || (/^\s{2,}\S/.test(linhas[i]) && itens.length))) {
          const m = linhas[i].match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
          if (m && m[1].length < 2) itens.push({ txt: m[3], sub: [] });
          else if (m) itens[itens.length - 1].sub.push({ ord: /\d/.test(m[2]), txt: m[3] });
          else itens[itens.length - 1].txt += ` ${linhas[i].trim()}`;
          i += 1;
        }
        const tag = ord ? 'ol' : 'ul';
        out.push(`<${tag}>${itens.map((it) => `<li>${inline(it.txt)}${it.sub.length ? `<${it.sub[0].ord ? 'ol' : 'ul'}>${it.sub.map((s) => `<li>${inline(s.txt)}</li>`).join('')}</${it.sub[0].ord ? 'ol' : 'ul'}>` : ''}</li>`).join('')}</${tag}>`);
        continue;
      }
      // parágrafo (até linha vazia ou início de outro bloco)
      const buf = [];
      while (i < linhas.length && linhas[i].trim() && !/^(#{1,4}\s|```|>|\s*([-*]|\d+\.)\s+|\s*---\s*$)/.test(linhas[i])
        && !(linhas[i].includes('|') && i + 1 < linhas.length && /^\s*\|?\s*:?-{2,}/.test(linhas[i + 1]))) {
        buf.push(linhas[i]);
        i += 1;
      }
      if (!buf.length) { buf.push(linhas[i]); i += 1; }
      out.push(`<p>${buf.map(inline).join('<br>')}</p>`);
    }
    return { html: out.join('\n'), titulos };
  }

  window.NGMarkdown = { render, slug };
})();
