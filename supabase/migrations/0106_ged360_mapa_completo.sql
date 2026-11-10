-- NIOGEN | supabase/migrations/0106_ged360_mapa_completo.sql | 10/11/2026 — Claude Code
-- 1ª rodada real do robô do GED360 (login TT837722, 10/11 ~15h45): lista completa de "Resultado da Análise" lida no filtro do
-- Relatório Detalhado + o que o CSV já trouxe (CONCLUÍDO, LINK EXPIRADO, ALERTA DE RISCO). Completa o config_biometria_resultado
-- (regra 15: nada no código). Texto que o NIOGEN não conhece continua "desconhecido" (guarda, avisa o admin, não mexe na venda).
insert into public.config_biometria_resultado (resultado, acao, nivel, texto, rotulo) values
  ('DOC. EM ANÁLISE', 'espera', null, 'aguardando a Nio conferir', 'Doc. em análise'),
  ('DOC EM ANALISE', 'espera', null, 'aguardando a Nio conferir', 'Doc. em análise'),
  ('DOC  EM ANALISE', 'espera', null, 'aguardando a Nio conferir', 'Doc. em análise'),
  ('DOC. NÃO APTO PARA VENDA', 'alerta', 'agora', 'Documento NÃO apto para venda no GED360 · ver o motivo e refazer com o cliente', 'Doc. não apto'),
  ('DOC. AUSENTE/DIGITALIZAR NOVAMENTE', 'alerta', 'agora', 'GED360: documento ausente · pedir novo link à Nio e orientar o cliente a refazer', 'Doc. ausente'),
  ('DOC. ILEGÍVEL/DIGITALIZAR NOVAMENTE', 'alerta', 'agora', 'GED360: documento ilegível · pedir novo link à Nio e orientar o cliente a refazer', 'Doc. ilegível'),
  ('DOC. INCOMPLETO/DIGITALIZAR NOVAMENTE', 'alerta', 'agora', 'GED360: documento incompleto · pedir novo link à Nio e orientar o cliente a refazer', 'Doc. incompleto'),
  ('NAO PASSIVEL DE ANALISE', 'alerta', 'agora', 'GED360: não passível de análise · pedir novo link à Nio e avisar o cliente', 'Não passível de análise'),
  ('COM RISCO', 'risco', 'agora', 'Biometria COM RISCO · falar com o cliente agora', 'Com risco'),
  ('COM RISCO APARENTE', 'risco', 'agora', 'Biometria com RISCO APARENTE · falar com o cliente agora', 'Risco aparente'),
  ('NEUTRO', 'alerta', 'hoje', 'GED360 deu NEUTRO · conferir no portal se a biometria foi aceita', 'Neutro')
on conflict (parceiro_id, resultado) do nothing;
